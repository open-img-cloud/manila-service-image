# Manila Service Image cloud images

Signed service images for the OpenStack Manila **generic driver** (NFS and
CIFS share servers), built per OpenStack series, part of the
[openimages.cloud](https://openimages.cloud) catalog.

- Catalog page: <https://openimages.cloud/images/manila-service-image/>
- Registry: <https://images.openimages.cloud/manila-service-image/latest/>

## About

The Manila generic driver (`manila.share.drivers.generic.GenericShareDriver`,
`driver_handles_share_servers = True`) creates one Nova instance per share
server, attaches Cinder volumes to it and exports them over NFS or CIFS. That
instance boots from a dedicated **service image**, built upstream by
[`openstack/manila-image-elements`][mie] with
[diskimage-builder][dib]. Like [`octavia-amphora`][octavia], this is an
**OpenStack control plane component**: Manila boots it, tenants never do.

This repo builds the same image as upstream's default build
(`tox -e buildimage`, the one published on [tarballs.opendev.org][tarballs]):
Ubuntu minimal plus the elements `manila-ssh`, `vm`, `dhcp-all-interfaces`,
`ubuntu-nfs` (nfs-kernel-server) and `ubuntu-cifs` (Samba with registry
configuration). It then signs it with cosign (keyless) and publishes it
through the shared openimages.cloud pipeline. Differences from upstream:

- **No password.** Upstream bakes the password `manila` into its image. Here
  the `manila` user has no password: access is by SSH key only (see below).
- **Pinned elements.** `manila-image-elements` is branchless (master only, last
  tag 1.3.0 in 2017). `build/dib-build.sh` pins a reviewed commit (`MIE_REF`)
  instead of building whatever master is at build time, and fails if the
  upstream element list drifts from ours.

The build pipeline is shared with the rest of
[`open-img-cloud`](https://github.com/open-img-cloud): this repo only ships
`VERSION`, `build/dib-build.sh`, `build/detect-upstream.sh` and thin caller
workflows that delegate to the reusable workflows in
[`open-img-cloud/.github`](https://github.com/open-img-cloud/.github) (`@main`).

## Versioning

`<version>` is the **OpenStack series** (e.g. `2026.2`), the Manila release the
image is published for. The guest content comes from the pinned
`manila-image-elements` commit; the series selects the
`openstack/requirements` upper-constraints (hence the diskimage-builder
version) and labels the image. The service image only needs SSH, sudo, NFS and
Samba, so one image works across the supported series.

| OpenStack series | Codename | Manila branch  | Status here |
|------------------|----------|----------------|-------------|
| 2025.2           | Flamingo | stable/2025.2  | buildable   |
| 2026.1           | Gazpacho | stable/2026.1  | buildable   |
| 2026.2           | Hibiscus | stable/2026.2  | default     |

Guest OS: Ubuntu 22.04 (jammy), the release upstream builds and tests in its
gate. Ubuntu 24.04 (noble) is not exercised upstream yet; it can be tried by
changing `MANILA_IMG_OS_VER` in `build/dib-build.sh`.

## Image

- File: `manila-service-image-<version>-amd64.qcow2` (e.g.
  `manila-service-image-2026.2-amd64.qcow2`).
- User: `manila`, passwordless sudo, **no password**. At boot,
  `fetch-public-ssh-keys.service` reads the instance key from the metadata
  service (`169.254.169.254`) into `~manila/.ssh/authorized_keys`. There is no
  cloud-init and no ConfigDrive support: the metadata service must be
  reachable from the service network.
- Services: `nfs-kernel-server`, `smbd` (registry configuration, managed by
  Manila through `net conf`), `qemu-guest-agent`.

## Use it (Manila operators)

```sh
V=2026.2
curl -fLO https://images.openimages.cloud/manila-service-image/$V/manila-service-image-$V-amd64.qcow2

openstack image create \
    --disk-format qcow2 --container-format bare \
    --property hw_qemu_guest_agent=yes \
    --file manila-service-image-$V-amd64.qcow2 \
    manila-service-image
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

Upstream reference: [generic driver documentation][generic].

## Verify before deploy

```sh
sha256sum -c <filename>.sha256
cosign verify-blob \
    --bundle <filename>.bundle \
    --new-bundle-format \
    --certificate-identity-regexp '^https://github.com/open-img-cloud/\.github/\.github/workflows/build-dib-image\.yml@' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    <filename>
```

The certificate identity is the reusable DIB workflow in
`open-img-cloud/.github`; `MANIFEST.json` ties the artifact to this repo's
commit and build run. More in the [verification guide](https://openimages.cloud/verify/).

## Release flow

1. `watch.yml` runs daily (07:20 UTC) and opens an `auto/upstream-bump` pull
   request when Manila gets a new `stable/YYYY.N` branch.
2. Merge it, then push the tag `v<VERSION>`: `release.yml` calls
   `build-dib-image.yml@main`, which runs `build/dib-build.sh` in a privileged
   `ubuntu:24.04` container on a GitHub-hosted runner, signs and publishes the
   image (versioned path, `latest/`, `versions.json`).
3. An older series can be rebuilt with `workflow_dispatch` (`version` input):
   `latest/` only moves for the newest series. `sync-latest.yml` repoints
   `latest/` to an already published version without rebuilding.
4. When `manila-image-elements` master gets relevant fixes, bump `MIE_REF` in
   `build/dib-build.sh` by pull request, then republish.

## Testing

No runtime smoke yet (`runtime_smoke_login_user` is unset on purpose): the
shared `smoke-openstack` contract (cloud-init, hostname from metadata, root
grown to the flavor disk) does not apply to a service image. Planned check,
closer to what Manila does: boot it with a Nova key pair, SSH in as `manila`
with that key, then assert `sudo -n true`, an empty or locked password
(`passwd -S manila`), `nfs-kernel-server` and `smbd` active, `exportfs` and
`net conf list` working, and password authentication refused.

## Repository layout

```
VERSION                     OpenStack series, e.g. 2026.2
build/
  dib-build.sh              DIB build hook (out dir as $1, version as $2)
  detect-upstream.sh        newest Manila stable/YYYY.N branch
.github/workflows/
  release.yml               tag push: calls build-dib-image.yml
  watch.yml                 daily: calls upstream-watch.yml
  sync-latest.yml           manual: point latest/ to a published version
.gitignore                  repo-local override for the global build/ exclusion
LICENSE                     GPL-2.0
```

## License

The build tooling in this repository is [GPL-2.0](LICENSE). The image content
keeps its own licenses (`manila-image-elements` and diskimage-builder are
Apache-2.0; Ubuntu packages under their respective licenses). OpenStack is a
trademark of the Open Infrastructure Foundation. This project is not
affiliated with it.

[mie]: https://opendev.org/openstack/manila-image-elements
[dib]: https://docs.openstack.org/diskimage-builder/
[octavia]: https://github.com/open-img-cloud/octavia-amphora
[tarballs]: https://tarballs.opendev.org/openstack/manila-image-elements/images/
[generic]: https://docs.openstack.org/manila/latest/admin/generic_driver.html
