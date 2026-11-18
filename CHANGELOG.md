# Changelog

## [0.2.0](https://github.com/GlueOps/terraform-provider-proxmox/compare/v0.1.0...v0.2.0) (2026-11-18)


### ⚠ BREAKING CHANGES

* proxmox_cloudinit_bootstrap fails instead of replacing an existing file named file_name, deletes only the ISO it uploaded (recorded in seed_file_id), and fails the apply when user_data, meta_data, network_config or vendor_data change after the bootstrap; replace the VM or add them to ignore_changes. file_name is optional again and defaults to cloudinit-bootstrap-<vm_id>.iso.

### Features

* only remove seed ISOs the bootstrap uploaded, and reject seed content changes ([#20](https://github.com/GlueOps/terraform-provider-proxmox/issues/20)) ([a20766e](https://github.com/GlueOps/terraform-provider-proxmox/commit/a20766e959f5a19ef6137ab6c9f8d917eed1ba81))

## [0.1.0](https://github.com/GlueOps/terraform-provider-proxmox/compare/v0.0.5...v0.1.0) (2026-11-13)


### ⚠ BREAKING CHANGES

* proxmox_cloudinit_bootstrap requires file_name, a name ending in .iso that uses only letters, digits, '.', '_' and '-' and is unique on the datastore.

### Features

* require file_name on proxmox_cloudinit_bootstrap ([#17](https://github.com/GlueOps/terraform-provider-proxmox/issues/17)) ([626a7a2](https://github.com/GlueOps/terraform-provider-proxmox/commit/626a7a2183a1b1c578969d594d70f102846a78b3))

## [0.0.5](https://github.com/GlueOps/terraform-provider-proxmox/compare/v0.0.4...v0.0.5) (2026-11-12)


### Bug Fixes

* **lab:** clear errors from check and load, one answer for a failed check ([#15](https://github.com/GlueOps/terraform-provider-proxmox/issues/15)) ([239b6a4](https://github.com/GlueOps/terraform-provider-proxmox/commit/239b6a4ddcedadab400385470c2a30048bccbb98))

## [0.0.4](https://github.com/GlueOps/terraform-provider-proxmox/compare/v0.0.3...v0.0.4) (2026-11-12)


### Features

* add the release gate lab on Hetzner and make the gate the lab's acceptance tests ([#13](https://github.com/GlueOps/terraform-provider-proxmox/issues/13)) ([df6b73c](https://github.com/GlueOps/terraform-provider-proxmox/commit/df6b73cdea0f637a8a90d4b2b3457a934f4b5b82))

## [0.0.3](https://github.com/GlueOps/terraform-provider-proxmox/compare/v0.0.2...v0.0.3) (2026-11-12)


### docs

* note that immutable releases are on ([#11](https://github.com/GlueOps/terraform-provider-proxmox/issues/11)) ([8e7a408](https://github.com/GlueOps/terraform-provider-proxmox/commit/8e7a408f523bd9256a005da3dc43dc7a6c89c590))

## [0.0.2](https://github.com/GlueOps/terraform-provider-proxmox/compare/v0.0.1...v0.0.2) (2026-11-12)


### Bug Fixes

* publish releases only after assets are uploaded ([#9](https://github.com/GlueOps/terraform-provider-proxmox/issues/9)) ([9aece7a](https://github.com/GlueOps/terraform-provider-proxmox/commit/9aece7a0611bc4f2f3f524b735a7a00530a77ad7))

## 0.0.1 (2026-11-12)


### Features

* set up the GlueOps fork based on bpg v0.122.0 ([#7](https://github.com/GlueOps/terraform-provider-proxmox/issues/7)) ([b37a941](https://github.com/GlueOps/terraform-provider-proxmox/commit/b37a941c3d8df991a4188f72a482d376e725b916))
