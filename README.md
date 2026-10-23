# OpenMRS nightly build server on DigitalOcean

Provisions a single Droplet that, every night at 02:00 UTC:

1. pulls [openmrs-distro-referenceapplication](https://github.com/digipaths-lk/openmrs-distro-referenceapplication) and [openmrs-esm-patient-chart](https://github.com/digipaths-lk/openmrs-esm-patient-chart)
2. builds and `npm pack`s the custom `esm-patient-chart-app`, `esm-form-engine-app` and `esm-patient-digipaths-app` modules in a throwaway `node:22` container
3. copies those tarballs into the distro's `frontend/` (where `*.tgz` is gitignored), then runs `docker compose build` and `up -d`

It serves the result over HTTPS with Let's Encrypt. Nothing is committed to, or required in, the distro or chart repos.

| File | Purpose |
|------|---------|
| `cloud-init.yaml` | First-boot setup: swap, Docker, clones of all three repos, generated `.env`, systemd timer |
| `nightly-build.sh` | What the timer runs; it `git pull`s this repo first, so script changes apply from the next run |

Server layout:

```
/etc/openmrs-nightly/settings   branches, repo URLs, domain, WIPE_DATA (re-read every run)
/opt/openmrs/deploy             this repo
/opt/openmrs/distro             distro checkout (+ untracked .env with generated DB passwords)
/opt/openmrs/chart              patient-chart checkout
/opt/frontend-tgz               frontend tarballs built from the chart repo
```

## Prerequisites

- This repo pushed somewhere the Droplet can clone (set `DEPLOY_REPO_URL`)
- `doctl` authenticated (`doctl auth init`) and an SSH key uploaded (`doctl compute ssh-key list`)
- A domain/subdomain you can point at the Droplet

## Setup

1. Edit the `settings` block at the top of `cloud-init.yaml`.

2. Create the Droplet. 8 GB RAM is the practical minimum because the chart, SPA and Maven builds run alongside a live OpenMRS:

   ```bash
   doctl compute droplet create openmrs-nightly \
     --region lon1 --size s-4vcpu-8gb --image ubuntu-24-04-x64 \
     --ssh-keys <key-id> --tag-name openmrs \
     --user-data-file cloud-init.yaml --wait
   ```

3. Add a firewall. The distro's compose file publishes MariaDB on 3306, and Docker bypasses `ufw`, so a cloud firewall is the reliable way to close it:

   ```bash
   doctl compute firewall create --name openmrs-fw --tag-names openmrs \
     --inbound-rules "protocol:tcp,ports:22,address:0.0.0.0/0 protocol:tcp,ports:80,address:0.0.0.0/0 protocol:tcp,ports:443,address:0.0.0.0/0" \
     --outbound-rules "protocol:tcp,ports:all,address:0.0.0.0/0 protocol:udp,ports:all,address:0.0.0.0/0 protocol:icmp,address:0.0.0.0/0"
   ```

4. Point a DNS `A` record for `DOMAIN` at the Droplet IP. This must happen before the first build, or Let's Encrypt validation fails.

5. Wait for cloud-init to finish, then run the first build:

   ```bash
   ssh root@<ip> cloud-init status --wait
   ssh root@<ip> 'systemctl start --no-block openmrs-nightly && journalctl -fu openmrs-nightly'
   ```

OpenMRS is then at `https://<DOMAIN>/openmrs/spa` (admin / Admin123; change it). The first backend start runs Liquibase and Initializer and can take 10–20 minutes.

## Operating it

```bash
systemctl list-timers openmrs-nightly        # next scheduled run
journalctl -u openmrs-nightly --since today  # build log
systemctl start openmrs-nightly              # build now
cd /opt/openmrs/distro && docker compose ps  # stack status
cat /var/log/cloud-init-output.log           # first-boot problems
```

- **Change branches or wipe behaviour:** edit `/etc/openmrs-nightly/settings`. If you change a branch, the next run checks it out.
- **Module versions must agree.** The distro's `frontend/Dockerfile` and `spa-assemble-config.json` name each tarball by exact version (e.g. `openmrs-esm-patient-chart-app-12.3.4-7.tgz`). When a `package.json` version is bumped in the chart repo, make the matching change in the distro. Otherwise the run stops before building and logs which file is missing and which are available.
- **DB passwords** are generated on first boot into `/opt/openmrs/distro/.env`. Don't change them after the database volume exists, because MariaDB only reads them on initialisation.
- If any step fails, `set -e` stops the script before `up -d`, so the previous night's containers keep running.
- Frontend modules pinned to `next` in the distro follow upstream, so a nightly build can change or break without a commit to either repo.
