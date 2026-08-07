import Fastify from "fastify";
import fastifyStatic from "@fastify/static";
import { readFile, rename, writeFile } from "node:fs/promises";

const app = Fastify({
  logger: true
});

const inventoryPath =
  process.env.INVENTORY_PATH ?? "/data/inventory/hosts.json";

const proxmoxPath =
  process.env.PROXMOX_PATH ?? "/data/http/proxmox";

const provisionIp =
  process.env.PROVISION_IP ?? "192.168.50.1";

const port = Number(process.env.PORT ?? 80);
const host = process.env.HOST ?? "0.0.0.0";

async function readInventory() {
  try {
    const content = await readFile(inventoryPath, "utf8");
    return JSON.parse(content);
  } catch (error) {
    if (error.code === "ENOENT") {
      return {};
    }

    throw error;
  }
}

async function writeInventory(inventory) {
  const temporaryPath = `${inventoryPath}.tmp`;
  const content = `${JSON.stringify(inventory, null, 2)}\n`;

  // Write and rename so readers never see a partially written JSON file.
  await writeFile(temporaryPath, content, "utf8");
  await rename(temporaryPath, inventoryPath);
}

function normalizeMac(value) {
  return String(value ?? "")
    .trim()
    .toLowerCase()
    .replaceAll("-", ":");
}

function hostnameFromMac(mac) {
  const suffix = mac.replaceAll(":", "").slice(-6);
  return `pve-${suffix}`;
}

/*
 * Serve the generated Proxmox PXE artifacts directly from Node.js.
 *
 * Examples:
 *   /proxmox/boot.ipxe
 *   /proxmox/vmlinuz
 *   /proxmox/initrd.img
 */
await app.register(fastifyStatic, {
  root: proxmoxPath,
  prefix: "/proxmox/",
  decorateReply: false
});

app.get("/health", async () => {
  return {
    status: "ok"
  };
});

app.post("/answer", async (request, reply) => {
  app.log.info(
    {
      body: request.body,
      headers: request.headers
    },
    "Proxmox installer requested an answer file"
  );

  const answer = `
[global]
keyboard = "en-us"
country = "de"
fqdn = "pve01.example.internal"
mailto = "admin@example.internal"
timezone = "Europe/Berlin"
root-password = "REPLACE_WITH_A_TEMPORARY_PASSWORD"
reboot-on-error = false

[network]
source = "from-dhcp"

[disk-setup]
filesystem = "ext4"
disk-list = ["nvme0n1"]
`;

  reply.type("text/plain; charset=utf-8");
  return answer.trimStart();
});

app.get("/ipxe/boot", async (request, reply) => {
  const mac = normalizeMac(request.query.mac);

  reply.type("text/plain; charset=utf-8");

  if (!/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/.test(mac)) {
    reply.code(400);

    return `#!ipxe
echo Invalid MAC address
sleep 5
exit
`;
  }

  const inventory = await readInventory();

  let hostEntry = inventory[mac];

  if (!hostEntry) {
    hostEntry = {
      hostname: hostnameFromMac(mac),
      action: "install",
      discoveredAt: new Date().toISOString(),
      status: "discovered"
    };

    inventory[mac] = hostEntry;
    await writeInventory(inventory);

    app.log.info(
      {
        mac,
        hostname: hostEntry.hostname
      },
      "Automatically registered new PXE client"
    );
  }

  if (hostEntry.action === "local") {
    return `#!ipxe
echo Hostname : ${hostEntry.hostname}
echo Action   : local boot
sleep 2
exit
`;
  }

  if (hostEntry.action === "install") {
    return `#!ipxe
echo Proxmox installation authorized
echo Hostname: ${hostEntry.hostname}
echo MAC: ${mac}

chain http://${provisionIp}/proxmox/boot.ipxe || goto failed

:failed
echo Failed to load Proxmox installer
echo Error: \${errno}
shell
`;
  }

  return `#!ipxe
echo Unsupported action: ${hostEntry.action}
sleep 5
exit
`;
});

try {
  await app.listen({
    port,
    host
  });
} catch (error) {
  app.log.error(error);
  process.exit(1);
}
