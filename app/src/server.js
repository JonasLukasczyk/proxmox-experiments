import Fastify from "fastify";
import fastifyStatic from "@fastify/static";
import { readFile, rename, writeFile } from "node:fs/promises";

const app = Fastify({
  logger: true
});

const inventoryPath =
  process.env.INVENTORY_PATH ?? "/data/inventory/hosts.json";

const proxmoxPath =
  process.env.PROXMOX_PATH ?? "/data/proxmox";

const provisionIp =
  process.env.PROVISION_IP ?? "192.168.50.1";

const port = Number(process.env.PORT ?? 80);
const host = process.env.HOST ?? "0.0.0.0";

const macPattern = /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/;

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

  // Write and rename so readers never see partially written JSON.
  await writeFile(temporaryPath, content, "utf8");
  await rename(temporaryPath, inventoryPath);
}

function normalizeMac(value) {
  return String(value ?? "")
    .trim()
    .toLowerCase()
    .replaceAll("-", ":");
}

function isValidMac(mac) {
  return macPattern.test(mac);
}

function hostnameFromMac(mac) {
  const suffix = mac.replaceAll(":", "").slice(-6);
  return `pve-${suffix}`;
}

function installerScript(hostEntry, mac) {
  return `#!ipxe
echo Starting Proxmox installation
echo Hostname: ${hostEntry.hostname}
echo MAC: ${mac}

chain http://${provisionIp}/proxmox/boot.ipxe || goto failed

:failed
echo Failed to load Proxmox installer
echo Error: \${errno}
shell
`;
}

/*
 * Serve generated Proxmox PXE artifacts.
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

/*
 * Health check.
 */
app.get("/health", async () => {
  return {
    status: "ok"
  };
});

/*
 * Proxmox automated installer answer file.
 */
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
root-password = "rootroot"
reboot-on-error = false

[network]
source = "from-dhcp"

[disk-setup]
filesystem = "ext4"
disk-list = ["nvme0n1"]

[first-boot]
source = "from-iso"
ordering = "fully-up"
`;

  reply.type("text/plain; charset=utf-8");
  return answer.trimStart();
});

/*
 * Start an installation.
 *
 * Both cases end up here:
 *
 *   1. action=install
 *      -> explicitly requested reinstall
 *
 *   2. action=local
 *      -> local boot failed
 *      -> fall back to installation
 *
 * Before booting the installer, action is reset to "local".
 * This prevents the machine from reinstalling again after the installer
 * reboots.
 */
app.get("/ipxe/install", async (request, reply) => {
  const mac = normalizeMac(request.query.mac);

  reply.type("text/plain; charset=utf-8");

  if (!isValidMac(mac)) {
    reply.code(400);

    return `#!ipxe
echo Invalid MAC address
shell
`;
  }

  const inventory = await readInventory();
  const hostEntry = inventory[mac];

  if (!hostEntry) {
    reply.code(404);

    return `#!ipxe
echo Unknown host
shell
`;
  }

  hostEntry.action = "local";
  hostEntry.status = "installing";
  hostEntry.installStartedAt = new Date().toISOString();

  inventory[mac] = hostEntry;
  await writeInventory(inventory);

  app.log.info(
    {
      mac,
      hostname: hostEntry.hostname
    },
    "Starting Proxmox installation"
  );

  return installerScript(hostEntry, mac);
});

/*
 * Main PXE decision endpoint.
 */
app.get("/ipxe/boot", async (request, reply) => {
  const mac = normalizeMac(request.query.mac);

  reply.type("text/plain; charset=utf-8");

  if (!isValidMac(mac)) {
    reply.code(400);

    return `#!ipxe
echo Invalid MAC address
sleep 5
exit
`;
  }

  const inventory = await readInventory();

  let hostEntry = inventory[mac];

  /*
   * Unknown machines are discovered conservatively.
   *
   * action=local means:
   *   try local boot first,
   *   then install if local boot fails.
   *
   * This prevents an existing Proxmox installation from being wiped merely
   * because hosts.json was reset.
   */
  if (!hostEntry) {
    hostEntry = {
      hostname: hostnameFromMac(mac),
      action: "local",
      status: "discovered",
      discoveredAt: new Date().toISOString()
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

  /*
   * Explicit installation request.
   *
   * Do not attempt local boot first.
   */
  if (hostEntry.action === "install") {
    return `#!ipxe
echo Hostname : ${hostEntry.hostname}
echo MAC      : ${mac}
echo Action   : forced installation

chain http://${provisionIp}/ipxe/install?mac=${mac} || goto failed

:failed
echo Failed to start Proxmox installer
echo Error: \${errno}
shell
`;
  }

  /*
   * "local" means:
   *
   *   1. Try to boot the local disk.
   *   2. If local boot fails, fall back to installation.
   *
   * If sanboot succeeds, execution never reaches :install because control
   * transfers to the locally installed operating system.
   */
  if (hostEntry.action === "local") {
    return `#!ipxe
echo Hostname : ${hostEntry.hostname}
echo MAC      : ${mac}
echo Status   : ${hostEntry.status}
echo Action   : prefer local boot

echo Trying local boot...

sanboot --no-describe --drive 0x80 || goto install

:install
echo Local boot failed
echo Falling back to Proxmox installation...

chain http://${provisionIp}/ipxe/install?mac=${mac} || goto failed

:failed
echo Failed to start Proxmox installer
echo Error: \${errno}
shell
`;
  }

  return `#!ipxe
echo Unsupported action: ${hostEntry.action}
shell
`;
});

/*
 * Called by the installed Proxmox system after it has successfully booted.
 *
 * This confirms that the installation is usable, rather than merely that the
 * installer started successfully.
 */
app.post("/confirmInstalled", async (request, reply) => {
  const mac = normalizeMac(request.query.mac);

  if (!isValidMac(mac)) {
    return reply.code(400).send({
      error: "Invalid MAC address"
    });
  }

  const inventory = await readInventory();
  const hostEntry = inventory[mac];

  if (!hostEntry) {
    return reply.code(404).send({
      error: "Unknown host"
    });
  }

  hostEntry.action = "local";
  hostEntry.status = "installed";
  hostEntry.installedAt = new Date().toISOString();

  inventory[mac] = hostEntry;
  await writeInventory(inventory);

  app.log.info(
    {
      mac,
      hostname: hostEntry.hostname
    },
    "Proxmox installation confirmed"
  );

  return {
    status: "ok"
  };
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
