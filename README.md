# Pi-hole Automated Deployment

This repository provides a fully automated, production-grade installation of Pi-hole via Docker for a fresh Raspberry Pi OS. 

## Repository files

| File | Purpose |
| --- | --- |
| `install_pi-hole.sh` | Host provisioning, Docker install and stack deployment |
| `docker-compose.yml` | Pi-hole v6 container definition |
| `.env.example` | Template for `.env` (timezone and admin password) |
| `.gitignore` | Keeps `.env` and Pi-hole data directories out of Git |


## 1. Prerequisites

1. Flash a microSD card with **Raspberry Pi OS Lite (64-bit)** using the [Raspberry Pi Imager](https://www.raspberrypi.com/software/).
2. **Enable SSH**: In the Pi Imager OS Customization settings, enable SSH and configure your Wi-Fi and user credentials. 
   > *Tip: You can also enable SSH manually by placing an empty file exactly named `ssh` in the root of the `bootfs` partition on the SD card right after flashing.*

3. **Set a static IP**: give the Pi a fixed address so its DNS role survives reboots. Edit `/etc/dhcpcd.conf` and add (adjust the interface, address and router to match your network):
    ```conf
    interface eth0
    static ip_address=192.168.1.50/24
    static routers=192.168.1.1
    static domain_name_servers=1.1.1.1
    ```

## 2. Installation

SSH into your Raspberry Pi and run the following commands:

1. Clone this repository:
    ```bash
    git clone https://github.com/gabrielchv/pi-hole-setup.git
    cd pi-hole-setup
    ```

2. Set up your environment variables:
    ```bash
    cp .env.example .env
    nano .env
    ```
    *(Update the `WEBPASSWORD` to your preferred admin panel password, then save and exit).*

3. Run the automated deployment script:
    ```bash
    chmod +x install_pi-hole.sh
    sudo ./install_pi-hole.sh
    ```

The script will automatically provision the host, install Docker, configure system persistence, handle DNS pull loops, and deploy the Pi-hole v6 container. Once finished, your dashboard will be accessible at `http://<YOUR_PI_IP>/admin`.

## 3. Router Configuration

To enable network-wide ad blocking, you must route your network's DNS traffic through the Pi-hole:

1. Log into your home router's admin panel.
2. Locate the **LAN**, **DHCP**, or **DNS** settings.
3. Change the **Primary DNS Server** to your Raspberry Pi's static IP address. 
4. Leave the Secondary DNS completely blank.
5. **IPv6 Warning:** If your router utilizes IPv6, you must disable IPv6 Stateless DNS broadcasting (SLAAC) or point the IPv6 DNS to the Pi-hole as well, otherwise devices (like Android and Pop!_OS) will bypass the ad blocker.
6. Save your settings and disconnect/reconnect your devices to the Wi-Fi to refresh their network rules.