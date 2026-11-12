<p align="center">
  <a href="https://openimages.cloud/images/manila-service-image/">
    <img src="https://openimages.cloud/img/og/manila-service-image.png" alt="Manila service image for OpenStack" width="720">
  </a>
</p>

<p align="center">
  <a href="https://openimages.cloud/images/manila-service-image/"><img alt="Latest version" src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fimages.openimages.cloud%2Fmanila-service-image%2Flatest%2FMANIFEST.json&query=%24.version&label=latest&color=2459c4&cacheSeconds=3600"></a>
  <a href="https://github.com/open-img-cloud/manila-service-image/actions/workflows/release.yml"><img alt="Release" src="https://github.com/open-img-cloud/manila-service-image/actions/workflows/release.yml/badge.svg"></a>
  <a href="https://openimages.cloud/verify/"><img alt="Signed with Sigstore cosign" src="https://img.shields.io/badge/signed-Sigstore%20cosign-2459c4"></a>
  <a href="LICENSE"><img alt="License GPL-2.0" src="https://img.shields.io/badge/license-GPL--2.0-555"></a>
</p>

<p align="center">
  <a href="https://openimages.cloud/images/manila-service-image/"><b>Catalog page</b></a> ·
  <a href="https://images.openimages.cloud/manila-service-image/latest/">Download</a> ·
  <a href="https://openimages.cloud/verify/">Verify</a> ·
  <a href="https://github.com/open-img-cloud/docs">Documentation</a> ·
  <a href="https://github.com/open-img-cloud/manila-service-image/issues">Report an issue</a>
</p>

Manila service image (qcow2) for **OpenStack**: the share server image of the Manila
**generic driver** (NFS and CIFS), built per OpenStack series from
[`openstack/manila-image-elements`](https://opendev.org/openstack/manila-image-elements) with
[diskimage-builder](https://docs.openstack.org/diskimage-builder/) and signed with Sigstore
cosign, like every [openimages.cloud](https://openimages.cloud) image. It is an **OpenStack
control plane component**: Manila boots it, tenants never do.

## At a glance

| | |
|---|---|
| **Upstream** | [`manila-image-elements`](https://opendev.org/openstack/manila-image-elements) at a pinned, reviewed commit (`MIE_REF`), same element set as upstream's default build |
| **Guest OS** | Ubuntu 22.04 (jammy) minimal, the release upstream builds and tests in its gate |
| **User** | `manila`, SSH key only (fetched from the metadata service), passwordless `sudo` |
| **Services** | `nfs-kernel-server`, Samba `smbd` (registry configuration, managed by Manila through `net conf`), `qemu-guest-agent` |
| **Format** | qcow2, x86_64, `manila-service-image-<series>-amd64.qcow2` |
| **Version** | OpenStack series, e.g. `2026.2` ([all versions](https://images.openimages.cloud/manila-service-image/versions.json)) |

| OpenStack series | Codename | Manila branch | Status here |
|---|---|---|---|
| 2025.2 | Flamingo | stable/2025.2 | buildable |
| 2026.1 | Gazpacho | stable/2026.1 | buildable |
| 2026.2 | Hibiscus | stable/2026.2 | published, `latest/` |

The guest content comes from the pinned `manila-image-elements` commit; the series selects the
`openstack/requirements` upper-constraints (hence the diskimage-builder version) and labels the
image. The image only needs SSH, sudo, NFS and Samba, so one image works across the supported
series.

## Quick start

```sh
# Latest series and its file name, from the signed manifest
M=https://images.openimages.cloud/manila-service-image/latest/MANIFEST.json
V=$(curl -fsS $M | jq -r .version); F=$(curl -fsS $M | jq -r .filename)
curl -fLO https://images.openimages.cloud/manila-service-image/$V/$F
```

<details>
<summary><b>OpenStack (Manila operators)</b></summary>

```sh
openstack image create --disk-format qcow2 --container-format bare \
  --property hw_qemu_guest_agent=yes \
  --file "$F" manila-service-image
```

Then in `manila.conf`, in the generic back end section:

```ini
[generic]
share_driver = manila.share.drivers.generic.GenericShareDriver
driver_handles_share_servers = True
share_backend_name = GENERIC
# Glance image name (default: manila-service-image)
service_image_name = manila-service-image
# The only user in the image
service_instance_user = manila
# Key pair Manila registers in Nova and injects into each share server;
# the image fetches it from the metadata service. Leave
# service_instance_password unset: the image has no password.
manila_service_keypair_name = manila-service
path_to_public_key = /etc/manila/ssh/id_rsa.pub
path_to_private_key = /etc/manila/ssh/id_rsa
# devstack uses 1 vCPU, 512 MB RAM, 5 GB disk
service_instance_flavor_id = <flavor id>
```

Upstream reference: [generic driver documentation](https://docs.openstack.org/manila/latest/admin/generic_driver.html).

</details>

<details>
<summary><b>SSH access</b></summary>

At boot, `fetch-public-ssh-keys.service` reads the instance key from the metadata service
(`169.254.169.254`) into `~manila/.ssh/authorized_keys`. There is no cloud-init and no config
drive support: the metadata service must be reachable from the service network.

</details>

<details>
<summary><b>Verify the signature</b></summary>

```sh
curl -fLO https://images.openimages.cloud/manila-service-image/$V/$F.bundle
cosign verify-blob "$F" --bundle "$F.bundle" \
  --certificate-identity-regexp '^https://github.com/open-img-cloud/\.github/\.github/workflows/build-(libguestfs|dib|nix-flake|freebsd)-image\.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

The certificate identity is the shared DIB build workflow; `MANIFEST.json` ties the file to
this repository's commit and build run.

</details>

## What this image changes

It is the image of upstream's default build (`tox -e buildimage`, the one published on
[tarballs.opendev.org](https://tarballs.opendev.org/openstack/manila-image-elements/images/)):
Ubuntu minimal plus the elements `manila-ssh`, `vm`, `dhcp-all-interfaces`, `ubuntu-nfs` and
`ubuntu-cifs`. Differences from upstream:

- **No password.** Upstream bakes the password `manila` into its image. Here the `manila` user
  has no password: access is by SSH key only.
- **Pinned elements.** `manila-image-elements` is branchless (master only).
  `build/dib-build.sh` pins a reviewed commit (`MIE_REF`) instead of building whatever master
  is at build time, and fails if the upstream element list drifts from ours.

## How it is validated

This image is **not boot-tested** by openimages.cloud: it has no cloud-init, keeps a fixed
hostname and does not grow its root disk, so the shared OpenStack runtime contract does not
apply. Each release is:

- built from the pinned elements, with a guard against upstream element drift;
- checksummed and signed with Sigstore cosign (keyless);
- validated after publication from the CDN: `MANIFEST.json` and its required keys, sidecar
  files, cache headers, size limit, and `cosign verify-blob` on the downloaded file.

Planned check, closer to what Manila does: boot it with a Nova key pair, SSH in as `manila`
with that key, then assert `sudo -n true`, an empty or locked password (`passwd -S manila`),
`nfs-kernel-server` and `smbd` active, `exportfs` and `net conf list` working, and password
authentication refused.

## How releases happen

1. Every day at 07:20 UTC a watcher looks for a new Manila `stable/YYYY.N` branch and opens a
   pull request that bumps [`VERSION`](VERSION).
2. Merging it is all it takes: the release is tagged, built, signed and published, then
   `latest/` and the [catalog](https://openimages.cloud/images/) move to it.
3. An older series can be rebuilt with `release.yml` (`workflow_dispatch`, `version` input):
   `latest/` only follows the newest series. `sync-latest.yml` points `latest/` to an already
   published series without rebuilding.
4. When `manila-image-elements` master gets relevant fixes, bump `MIE_REF` in
   `build/dib-build.sh` by pull request, then republish.

The build runs `build/dib-build.sh` in a privileged `ubuntu:24.04` container on a
GitHub-hosted runner (debootstrap needs full root capabilities). That container is not
signed by this project, so the builder signature check of the other images is off here.

This repository only holds what is specific to this image: [`VERSION`](VERSION),
[`build/dib-build.sh`](build/dib-build.sh), [`build/detect-upstream.sh`](build/detect-upstream.sh)
and thin workflows calling the shared pipeline in
[`open-img-cloud/.github`](https://github.com/open-img-cloud/.github).

## License

The build tooling in this repository is under [GPL-2.0](LICENSE). The image content keeps its
own licenses (`manila-image-elements` and diskimage-builder are Apache-2.0, Ubuntu packages
under their respective licenses). OpenStack is a trademark of the Open Infrastructure
Foundation; this project is not affiliated with it.
