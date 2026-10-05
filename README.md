[!["Buy Me A Coffee"](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/linuxshots)

# media-stack

A self-hosted media ecosystem that combines media management, streaming, AI-powered recommendations, and VPN.

This stack includes:

- **VPN:** ([Gluetun](https://github.com/qdm12/gluetun)) For secure and private media downloading
- **Radarr:** For movie management
- **Sonarr:** For TV show management
- **Prowlarr:** A torrent indexer manager for Radarr/Sonarr
- **qBittorrent:** Torrent client for downloading media
- **Seerr:** To manage media requests
- **Jellyfin:** Open-source media streamer
- **Recommendarr:** For AI-powered movie and show recommendations

## Requirements

- Docker version 28.0.1 or later
- Docker compose version v2.33.1 or later
- Older versions may work, but they have not been tested.

## How it fits together

```
Seerr ──► Radarr / Sonarr ──► Prowlarr ──► torrent indexers   (via VPN)
               │
               └──► qBittorrent ──► torrent peers              (via VPN)
               │
               └──► hardlinks finished files into media/ ──► Jellyfin
```

- **qBittorrent** and **Prowlarr** share the VPN container's network. All their traffic leaves through the VPN tunnel, and if the tunnel drops they lose internet access instead of falling back to your real IP.
- **Radarr, Sonarr, Seerr and Jellyfin** are *not* behind the VPN. They only talk to metadata services and to each other.
- Because of this, other containers reach qBittorrent at `vpn:5080` and Prowlarr at `vpn:9696` (not `qbittorrent` / `prowlarr`).

## Install media stack

> **⚠️ Important Notice for Jellyseerr/Seerr Users:**
> As of version 3, Jellyseerr and Overseerr have been unified into a single project called **Seerr**.
>
> If you're migrating from Jellyseerr to Seerr:
> - Use the same volume name (`jellyseerr-config`) to preserve your existing configuration and avoid data loss.
> - Before starting the Seerr container, change ownership of the config volume to UID 1000 (Seerr's non-root user), as Jellyseerr previously ran as `root`. Run the following command:
>
> `docker run --rm -v media-stack_jellyseerr-config:/data alpine chown -R 1000:1000 /data`

There are three ways to deploy this stack:

1. **With a VPN** (Recommended, and the default configuration in `docker-compose.yml`)
2. **Without a VPN**
3. **With Recommendarr** (An optional tool for AI-generated movie and show recommendations)

> **NOTE:** Every service is assigned to a profile (`vpn`, `no-vpn` or `recommendarr`).
> Running the `docker compose` command without a profile **will not deploy anything**.
> This prevents accidental or unintentional deployment of media-stack without VPN.

### 1. Create the Docker network

Before deploying the stack, you must first create a Docker network:

```bash
docker network create --subnet 172.20.0.0/16 mynetwork
# Update the CIDR range based on your available IP range
```

### 2. Prepare the storage folder

All media and downloads live under a single host folder, set with the `DATA_ROOT` variable
(default: `/Volumes/MediaServer/data`, an external drive). Create this layout:

```bash
mkdir -p "$DATA_ROOT"/{torrents,media}/{movies,tv}
```

```
$DATA_ROOT/
├── torrents/            # qBittorrent downloads   → /data/torrents in containers
│   ├── movies/
│   └── tv/
└── media/               # Final library           → /data/media in containers
    ├── movies/
    └── tv/
```

How the folders are mounted:

| Container | Host path | Container path |
|---|---|---|
| qBittorrent | `$DATA_ROOT/torrents` | `/data/torrents` |
| Radarr, Sonarr | `$DATA_ROOT` | `/data` |
| Jellyfin | `$DATA_ROOT/media` | `/data/media` |

Radarr and Sonarr see both `torrents/` and `media/` under the same `/data` mount. This lets them
**hardlink** finished downloads into the library instead of copying them, so a file isn't stored
twice and qBittorrent can keep seeding it. Don't split these into separate mounts.

> **NOTE (macOS / external drive):**
> - Docker Desktop must be allowed to access the drive: Settings → Resources → File sharing.
> - The drive must be **mounted before the containers are created**. If it isn't, Docker fails with
>   `mkdir /host_mnt/Volumes/...: permission denied`.
> - A container keeps the mount path it was created with. After changing `DATA_ROOT`, re-run
>   `docker compose --profile vpn up -d` so the containers are recreated, then confirm with
>   `docker inspect radarr --format '{{range .Mounts}}{{.Source}} {{end}}'`.
>   Otherwise, downloads can silently end up on the wrong disk.

### 3. Create the `.env` file

Settings are read from a `.env` file next to `docker-compose.yml`, which Compose loads automatically.
Add `.env` to `.gitignore`, since it holds your VPN credentials.

```env
# Host folder holding torrents/ and media/ (mounted at /data in the containers)
DATA_ROOT=/Volumes/MediaServer/data

# VPN (gluetun)
VPN_SERVICE_PROVIDER=protonvpn   # nordvpn, expressvpn, protonvpn, surfshark or custom
VPN_TYPE=openvpn                 # openvpn or wireguard
SERVER_COUNTRIES=Switzerland
# SERVER_CITIES=                 # Optional

# If VPN_TYPE=openvpn
OPENVPN_USER=
OPENVPN_PASSWORD=

# If VPN_TYPE=wireguard
# WIREGUARD_PRIVATE_KEY=
# WIREGUARD_ADDRESSES=           # Optional for protonvpn

# Static IPs on the "mynetwork" network (see "Static Container IP Requirement")
RADARR_STATIC_CONTAINER_IP=172.20.0.100
SONARR_STATIC_CONTAINER_IP=172.20.0.101
```

| Variable | Default | Purpose |
|---|---|---|
| `DATA_ROOT` | `/Volumes/MediaServer/data` | Host folder for downloads and media |
| `VPN_SERVICE_PROVIDER` | `nordvpn` | VPN provider (nordvpn, expressvpn, protonvpn, surfshark, custom) |
| `VPN_TYPE` | `openvpn` | `openvpn` or `wireguard` |
| `OPENVPN_USER` / `OPENVPN_PASSWORD` | empty | OpenVPN credentials (OpenVPN only) |
| `WIREGUARD_PRIVATE_KEY` / `WIREGUARD_ADDRESSES` | empty | WireGuard settings (WireGuard only) |
| `SERVER_COUNTRIES` / `SERVER_CITIES` | `Switzerland` / empty | Where to connect |
| `VPN_PORT_FORWARDING` | `off` | ProtonVPN port forwarding, see below |
| `RADARR_STATIC_CONTAINER_IP` / `SONARR_STATIC_CONTAINER_IP` | none (required) | Static IPs, see below |

Check what Compose resolves with `docker compose --profile vpn config`.

### 4. Configure your VPN provider

By default, **NordVPN** is the provider if `VPN_SERVICE_PROVIDER` isn't set, but you can switch to:

- **ExpressVPN**
- **SurfShark**
- **ProtonVPN**
- **Custom OpenVPN**
- **WireGuard VPN**

➡️ **Full list of supported VPN providers:** [VPN Providers](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers)

Switch between OpenVPN and WireGuard by changing `VPN_TYPE` in `.env`, then run
`docker compose --profile vpn up -d` again.

**OpenVPN:** Refer to your VPN provider's documentation to generate an **OpenVPN username and password**.
These are usually different from your normal account login. For ProtonVPN, find them at
account.protonvpn.com → Account → OpenVPN / IKEv2 username. See the
[Gluetun VPN Setup Guide](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers).

**WireGuard (ProtonVPN example):** Generate a WireGuard config at account.protonvpn.com → Downloads → WireGuard,
and put its private key in `WIREGUARD_PRIVATE_KEY`. Set `WIREGUARD_ADDRESSES` to the config's `Address`
only if your provider needs it.

**ProtonVPN free plan:** Uncomment `- FREE_ONLY=on` in the `vpn` service of `docker-compose.yml`, and set
`SERVER_COUNTRIES` to a country the free plan offers.

**ProtonVPN port forwarding (optional):** Set `VPN_PORT_FORWARDING=on` in `.env`. For OpenVPN, your
`OPENVPN_USER` must end in `+pmp`, and only P2P servers support it. Gluetun pushes the forwarded port into
qBittorrent automatically, which requires **Options → WebUI → "Bypass authentication for clients on localhost"**
to be enabled in qBittorrent.

### Static Container IP Requirement

A **static container IP address** is needed when **Prowlarr** is behind a VPN.
Since Prowlarr can only communicate with **Radarr** and **Sonarr** using their **container IP addresses**,
these must be **manually assigned** to avoid connection issues when containers restart.

Use `RADARR_STATIC_CONTAINER_IP` and `SONARR_STATIC_CONTAINER_IP` in `.env`, with free addresses inside the
`mynetwork` subnet. **Pick addresses high in the range** (for example `.100` and `.101`):
Docker assigns low addresses to other containers first, and a clash leaves Radarr or Sonarr stuck in the
`Created` state with `Address already in use`.
Check what's in use with `docker network inspect mynetwork`.

### 5. Deploy the stack with VPN

```bash
docker compose --profile vpn up -d

# OPTIONAL: Use Nginx as a reverse proxy
# docker compose -f docker-compose-nginx.yml up -d
```

You can also pass the same settings inline instead of using `.env`, for example:
`VPN_SERVICE_PROVIDER=nordvpn OPENVPN_USER=... OPENVPN_PASSWORD=... RADARR_STATIC_CONTAINER_IP=... SONARR_STATIC_CONTAINER_IP=... docker compose --profile vpn up -d`

### 6. Verify the VPN

`qbittorrent` and `prowlarr` should show the VPN's IP address, never your own:

```bash
docker logs vpn                                          # should show a connection and a public IP
docker exec qbittorrent curl -s https://ipinfo.io/ip     # VPN IP
docker exec prowlarr curl -s https://ipinfo.io/ip        # VPN IP
curl -s https://ipinfo.io/ip                             # your real IP, for comparison
docker inspect qbittorrent --format '{{.HostConfig.NetworkMode}}'   # container:<id>, not mynetwork
```

## Deploy the Stack Without VPN

🚨 **Warning:** Deploying without a VPN is **highly discouraged** as it may expose your IP address when torrenting media.

The VPN is on by default in `docker-compose.yml`. To run without it, you must edit the file. Inline comments
mark each line to flip:

- `qbittorrent`: comment out `depends_on` and `network_mode: service:vpn`, uncomment its `networks` and `ports`
- `prowlarr`: comment out `depends_on` and `network_mode: service:vpn`, uncomment its `networks` and `ports`
- `radarr` / `sonarr`: swap the static-IP `networks` block for the plain `- mynetwork` entry

Then run:

```bash
docker compose --profile no-vpn up -d

# OPTIONAL: Use Nginx as a reverse proxy
# docker compose -f docker-compose-nginx.yml up -d
```

## Deploy the Stack with Recommendarr (Optional)

**Recommendarr** is a web application that uses AI to generate personalized TV show and movie recommendations based on your:

- **Sonarr** library
- **Radarr** library
- **Jellyfin** watchlist and library
- **Trakt** watchlist (Optional)

### Deploying with Recommendarr

Run the following command based on your setup:

```bash
COMPOSE_PROFILES=vpn,recommendarr docker compose up -d  # With VPN

# COMPOSE_PROFILES=no-vpn,recommendarr docker compose up -d  # Without VPN
```

## Setup order

Configure the apps in this order, since each step uses what the previous one set up:
**qBittorrent → Radarr → Sonarr → Prowlarr → Jellyfin → Seerr**.

| App | URL |
|---|---|
| qBittorrent | http://localhost:5080 |
| Prowlarr | http://localhost:9696 |
| Radarr | http://localhost:7878 |
| Sonarr | http://localhost:8989 |
| Jellyfin | http://localhost:8096 |
| Seerr | http://localhost:5055 |

## Configure qBittorrent

- Open qBitTorrent at http://localhost:5080. Default username is `admin`. Temporary password can be collected from container log `docker logs qbittorrent`
- Go to Tools --> Options --> WebUI --> Change password
- Go to Tools --> Options --> Downloads:
  - Default Save Path: `/data/torrents`
  - Default Torrent Management Mode: **Automatic**
- No folder creation is needed: the `torrents/movies` and `torrents/tv` folders come from your `DATA_ROOT` layout (see "Prepare the storage folder"). Radarr and Sonarr create the `movies` and `tv` categories automatically when they send a download.

## Configure Radarr

- Open Radarr at http://localhost:7878
- Settings --> Media Management --> Check mark "Movies deleted from disk are automatically unmonitored in Radarr" under File management section --> Save
- Settings --> Media Management --> Scroll to bottom --> Add Root Folder --> Browse to `/data/media/movies` --> OK
- Settings --> Download clients --> qBittorrent --> Add Host (`vpn`) and port (5080) --> Username and password --> Category (`movies`) --> Test --> Save **Note: With the VPN enabled, qBittorrent is reachable on the VPN's service name, so use `vpn` in the Host field. Without the VPN, use `qbittorrent`.**
- Settings --> General --> Enable advance setting --> Select Authentication and add username and password
- Copy the API key from Settings --> General. Prowlarr needs it.
- Indexer will get automatically added during configuration of Prowlarr. See 'Configure Prowlarr' section.

Configure Sonarr in a similar way, with these differences:

- Root folder: `/data/media/tv`
- Download client category: `tv`
- Static IP / port for Prowlarr: `SONARR_STATIC_CONTAINER_IP`, port `8989`

**Add a movie** (After Prowlarr is configured)

- Movies --> Search for a movie --> Add Root folder (`/data/media/movies`) --> Quality profile --> Add movie
- Choose the quality profile carefully: a 2160p remux can be 50 GB or more.
- All queued movies download can be checked here, Activities --> Queue
- Go to qBittorrent (http://localhost:5080) and see if movie is getting downloaded (After movie is queued. This depends on availability of movie in indexers configured in Prowlarr.)

## Configure Prowlarr

- Open Prowlarr at http://localhost:9696
- Settings --> General --> Authentications --> Select Authentication and add username and password
- Add Indexers, Indexers --> Add Indexer --> Search for indexer --> Choose base URL --> Test and Save
- Add application, Settings --> Apps --> Add application --> Choose Radarr --> Prowlarr server (`http://vpn:9696`) --> Radarr server (`http://<RADARR_STATIC_CONTAINER_IP>:7878`, e.g. `http://172.20.0.100:7878`) --> API Key --> Test and Save
- Add application, Settings --> Apps --> Add application --> Choose Sonarr --> Prowlarr server (`http://vpn:9696`) --> Sonarr server (`http://<SONARR_STATIC_CONTAINER_IP>:8989`, e.g. `http://172.20.0.101:8989`) --> API Key --> Test and Save
- This will add indexers in respective apps automatically.

**Note: With the VPN enabled, Prowlarr cannot reach Radarr and Sonarr by `localhost` or container service name, so use their static IPs. Prowlarr is also not reachable by its own container name from other containers, so use `http://vpn:9696` as the Prowlarr server. (Without the VPN, use `http://prowlarr:9696`, `http://radarr:7878` and `http://sonarr:8989`.)**

## Configure Jellyfin

- Open Jellyfin at http://localhost:8096
- When you access the jellyfin for first time using browser, A guided configuration will guide you to configure jellyfin. Follow the guide **through the last screen**. Seerr can't sign in until the wizard is finished.
- Add media library folders: Movies --> `/data/media/movies`, Shows --> `/data/media/tv`

## Configure Seerr

- Open Seerr at http://localhost:5055
- When you access the seerr for first time using browser, A guided configuration will guide you to configure seerr.
- Choose **Jellyfin** as the media server. Hostname `jellyfin`, port `8096`, SSL off, and your Jellyfin username and password. Use `jellyfin`, not `localhost`: `localhost` inside the Seerr container means Seerr itself.
- Sync libraries and enable Movies and Shows.
- Add Radarr: hostname `radarr`, port `7878`, API key, then choose a quality profile and root folder `/data/media/movies`.
- Add Sonarr: hostname `sonarr`, port `8989`, API key, root folder `/data/media/tv`, and enable Season Folders.
- Follow the Seerr document for detailed setup - https://docs.seerr.dev/

## Troubleshooting

- **A container won't start with `permission denied` on `/host_mnt/Volumes/...`:** the external drive isn't mounted. Plug it in and re-run `docker compose --profile vpn up -d`.
- **Radarr or Sonarr stuck in `Created` with `Address already in use`:** its static IP is taken. Pick a higher address in `.env`, see "Static Container IP Requirement".
- **Downloads go to the wrong disk:** the containers were created with an old `DATA_ROOT`. Fix `.env` and re-run `docker compose --profile vpn up -d`.
- **Seerr warns "The `/app/config` volume mount was not configured properly":** the image's marker file was copied into the volume. Your data is saved. Remove the warning with `docker exec seerr rm /app/config/DOCKER`.
- **Radarr/Sonarr log `429 Too Many Requests` from an indexer:** the indexer is rate-limiting you. Radarr retries on the next search.
- **Prowlarr or qBittorrent has no internet:** the VPN is down. Check `docker logs vpn`.

## Configure Recommendarr

Recommendarr is an AI based movies/tvshows recommendation tool. To use this you will need any OpenAI API URL and API key with atleast one LLM model running. You can host your own OpenAI server with AI model using ollama or LM Studio. Or you can check `https://openrouter.ai` for limited-free LLMs.

- Open Recommendarr at http://localhost:3000
- Login with default username `admin` and password `1234`
- Settings --> Account --> Change Password and change your admin password
- Settings --> AI service --> API URL (Add OpenAI server API URL) --> API Key (Add OpenAPI server API key) --> Fetch available models --> Set Max tokens (best to keep it under 2000) --> Set Temperature (Best to keep at 0.8)
- Settings --> Sonarr --> Sonarr URL (http://sonarr:8989) --> API Keys (Sonarr API Key) --> Test Connection --> Save Sonarr setting
- Settings --> Radarr --> Radarr URL (http://radarr:7878) --> API Keys (Radarr API Key) --> Test Connection --> Save Radarr setting
- Settings --> Jellyfin --> Jellyfin URL (http://jellyfin:8096) --> API Keys (Jellyfin API Key) --> User ID (Add your jellyfin user id) --> Test Connection --> Save Jellyfin settings
- Test recommendarr: Recommendations --> Choose LLM Model from drop down list --> Enable Jellyfin Watch History toggle --> Select language --> Choose genres --> Discover recommendations
- You should be able to see recommendations based on your Jellyfin watch history

## Configure Nginx

- Get inside Nginx container
- `cd /etc/nginx/conf.d`
- Add proxies for all tools.

`docker cp nginx.conf nginx:/etc/nginx/conf.d/default.conf && docker exec -it nginx nginx -s reload`
- Close ports of other tools in firewall/security groups except port 80 and 443.


## Apply SSL in Nginx

- Open port 80 and 443.
- Get inside Nginx container and install certbot and certbot-nginx `apk add certbot certbot-nginx`
- Add URL in server block. e.g. `server_name  localhost mediastack.example.com;` in /etc/nginx/conf.d/default.conf
- Run `certbot --nginx` and provide details asked.

## Radarr Nginx reverse proxy

- Settings --> General --> URL Base --> Add base (/radarr)
- Add below proxy in nginx configuration

```
location /radarr {
    proxy_pass http://radarr:7878;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $http_connection;
  }
```

- Restart containers.

## Sonarr Nginx reverse proxy

- Settings --> General --> URL Base --> Add base (/sonarr)
- Add below proxy in nginx configuration

```
location /sonarr {
    proxy_pass http://sonarr:8989;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $http_connection;
  }
```

## Prowlarr Nginx reverse proxy

- Settings --> General --> URL Base --> Add base (/prowlarr)
- Add below proxy in nginx configuration

This may need to change configurations in indexers and base in URL.

```
location /prowlarr {
    proxy_pass http://prowlarr:9696; # Comment this line if VPN is enabled.
    # proxy_pass http://vpn:9696; # Uncomment this line if VPN is enabled.
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $http_connection;
  }
```

- Restart containers.

**Note: If VPN is enabled, then Prowlarr is reachable on vpn's service name**

## qBittorrent Nginx proxy

```
location /qbt/ {
    proxy_pass         http://qbittorrent:5080/; # Comment this line if VPN is enabled.
    # proxy_pass         http://vpn:5080/; # Uncomment this line if VPN is enabled.
    proxy_http_version 1.1;

    proxy_set_header   Host               http://qbittorrent:5080; # Comment this line if VPN is enabled.
    # proxy_set_header   Host               http://vpn:5080; # Uncomment this line if VPN is enabled.
    proxy_set_header   X-Forwarded-Host   $http_host;
    proxy_set_header   X-Forwarded-For    $remote_addr;
    proxy_cookie_path  /                  "/; Secure";
}
```

**Note: If VPN is enabled, then qbittorrent is reachable on vpn's service name**

## Jellyfin Nginx proxy

- Add base URL, Admin Dashboard -> Networking -> Base URL (/jellyfin)
- Add below config in Ngix config

```
 location /jellyfin {
        return 302 $scheme://$host/jellyfin/;
    }

    location /jellyfin/ {

        proxy_pass http://jellyfin:8096/jellyfin/;

        proxy_pass_request_headers on;

        proxy_set_header Host $host;

        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $http_host;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $http_connection;

        # Disable buffering when the nginx proxy gets very resource heavy upon streaming
        proxy_buffering off;
    }
```

## Seerr Nginx proxy

**Currently Seerr doesnot officially support the subfolder/path reverse proxy. They have a workaround documented here without an official support. Find it [here](https://docs.seerr.dev/extending-seerr/reverse-proxy)**

```
location / {
        proxy_pass http://127.0.0.1:5055;

        proxy_set_header Referer $http_referer;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Real-Port $remote_port;
        proxy_set_header X-Forwarded-Host $host:$remote_port;
        proxy_set_header X-Forwarded-Server $host;
        proxy_set_header X-Forwarded-Port $remote_port;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Ssl on;
    }
```

- Restart containers


## Disclaimer  

> Neither the author nor the developers of the code in this repository **condone or encourage** downloading, sharing, seeding, or peering of **copyrighted material**.  
> Such activities are **illegal** under international laws.  
>
> This project is intended for **educational purposes only**.  
