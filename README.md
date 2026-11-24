# Pi-hole Automated Deployment

One-command Pi-hole v6 on Raspberry Pi OS (or any Debian-derived host) using
Docker. Idempotent, pinned to a released image tag, and built so that a failure
halfway through leaves the previous deployment running.

## Repository files

| File | Purpose |
| --- | --- |
| `install_pi-hole.sh` | Preflight, Docker install, stack deployment, verification |
| `docker-compose.yml` | Pi-hole v6 container definition |
| `docker-compose.dhcp.yml` | Opt-in overlay that makes Pi-hole the DHCP server |
| `.env.example` | Template for `.env` (timezone, ports, image tag) |
| `.gitignore` | Keeps `.env`, `etc-pihole/` and query data out of Git |

## 1. Prerequisites

1. Flash a microSD card with **Raspberry Pi OS Lite (64-bit)** using the [Raspberry Pi Imager](https://www.raspberrypi.com/software/).
2. **Enable SSH**: in the Imager's OS Customization settings, enable SSH and set
   your Wi-Fi and user credentials.
   > *Tip: you can also enable SSH by placing an empty file named `ssh` in the
   > root of the `bootfs` partition after flashing.*
3. **Set a static IP**: a DNS server that moves breaks every client on the
   network. Edit `/etc/dhcpcd.conf` (adjust interface, address and router):
    ```conf
    interface eth0
    static ip_address=192.168.1.50/24
    static routers=192.168.1.1
    static domain_name_servers=1.1.1.1
    ```

## 2. Installation

```bash
git clone https://github.com/gabrielchv/pi-hole-setup.git
cd pi-hole-setup
sudo ./install_pi-hole.sh
```

That is the whole procedure. The script:

1. **Checks the host before changing it** — free disk, DNS resolution, port
   conflicts on 53/tcp+udp, 80 and 443, and whether a container named `pihole`
   already exists without belonging to this compose project.
2. **Creates `.env` (mode 600)** from `.env.example` if it is missing, copies the
   host timezone, and generates a 24-character admin password unless you set
   one.
3. **Installs Docker from Docker's signed apt repository** if it is missing — not
   from `curl | sh`. Use `--docker-script` only if you specifically want the
   convenience script.
4. **Pins and pulls `PIHOLE_VERSION`**, validates the compose file, and starts
   the stack.
5. **Waits for health, then proves it works**: a DNS query for `pi.hole` against
   the container, and an HTTP check on `/admin`.

Useful modes:

```bash
sudo ./install_pi-hole.sh --check            # report readiness, change nothing
./install_pi-hole.sh --dry-run               # print every command, change nothing
sudo ./install_pi-hole.sh --version 2027.01.0  # upgrade to a specific release
sudo ./install_pi-hole.sh --yes              # no confirmation prompt
```

The generated password is printed once and stored in `.env`. Change it in the
admin UI afterwards if the terminal output was captured somewhere.

### What the script deliberately does not do

- **It does not enable SSH.** Widening remote access is your decision, not an
  installer side effect.
- **It does not rewrite `/etc/resolv.conf`.** The previous version pointed it at
  `1.1.1.1` during the image pull and restored it with `mv`; on a
  `systemd-resolved` host that clobbers the symlink, and an interrupted run left
  the host with broken DNS. The script now verifies DNS works and stops with
  instructions instead.
- **It does not run `apt-get upgrade`.** Host upgrades stay on your schedule.

## 3. Router configuration

1. Log into your router's admin panel.
2. Find the **LAN**, **DHCP** or **DNS** settings.
3. Set the **Primary DNS Server** to the Pi's static IP.
4. Leave the **Secondary DNS** blank — a second resolver is a bypass.
5. **IPv6:** disable IPv6 stateless DNS broadcasting (SLAAC) or point IPv6 DNS at
   the Pi too, otherwise Android and Pop!_OS clients will resolve around it.
6. Reconnect clients (or renew their leases) to pick up the change.

### Using Pi-hole as the DHCP server (optional)

Set `PIHOLE_ENABLE_DHCP=true` and `PIHOLE_DHCP_START`, `PIHOLE_DHCP_END`,
`PIHOLE_DHCP_ROUTER` in `.env`, then re-run the installer. It adds
`docker-compose.dhcp.yml`, which publishes port 67 and enables FTL's DHCP
server. Keeping that in a separate overlay means a host that does not use DHCP
never exposes port 67 at all.

## 4. Updating Pi-hole

```bash
cd pi-hole-setup
git pull
sudo ./install_pi-hole.sh --version <new-tag>
```

Releases are listed at <https://hub.docker.com/r/pihole/pihole/tags>. The tag is
written to `.env`, so a rollback is the same command with the old tag. Data
lives in `etc-pihole/` (bind-mounted) and survives image changes.

## 5. Troubleshooting

**Port 53 already in use** — usually `systemd-resolved`'s stub listener:

```bash
sudo sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
sudo systemctl restart systemd-resolved
```

This keeps `resolved` for local name resolution and frees port 53. Disabling
`systemd-resolved` outright also works but takes local DNS with it. The
installer detects this case and prints these steps.

**Admin panel unreachable**

```bash
docker compose ps                 # health should be "healthy", not "starting"
docker compose logs --tail=50
```

**Container unhealthy** — the healthcheck asks FTL itself for `pi.hole`, so an
unhealthy container means DNS is not answering. Check that nothing else on the
host grabbed port 53 after boot.

**Ads still getting through** — confirm clients actually use the Pi
(`nslookup doubleclick.net <PI_IP>`), then revisit the IPv6 note above.

**Manual run without the script**

```bash
cp .env.example .env    # then fill WEBPASSWORD (12+ characters, no $ " ' # \ or spaces)
chmod 600 .env
docker compose up -d
```
