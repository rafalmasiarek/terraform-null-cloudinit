variable "cloud_config" {
  description = "Arbitrary cloud-config directives as a plain HCL object - escape hatch for anything the typed helpers below don't cover, or future cloud-init keys. Rendered as one text/cloud-config part, the #cloud-config header added automatically. A top-level key set here AND by a typed helper is a hard error - pick one mechanism per key."
  type        = any
  default     = null
}

variable "shell_scripts" {
  description = "Shell scripts to run, in order - each becomes one text/x-shellscript part (cloud-init's default/legacy script type, runs once per instance via the user-data module)."
  type        = list(string)
  default     = []
}

variable "cloudinit_parts" {
  description = "Escape hatch for anything else - arbitrary MIME parts (custom content_type, filename, merge_type). Appended last, after every other part this module generates."
  type = list(object({
    content_type = string
    content      = string
    filename     = optional(string)
    merge_type   = optional(string)
  }))
  default = []
}

variable "gzip" {
  description = "Gzip the rendered payload. AWS EC2's user_data size limit applies to the data as submitted (post-gzip, pre-base64) - enable this if the combined payload is large enough to hit max_bytes. cloud-init on Linux decompresses gzip automatically."
  type        = bool
  default     = false
}

variable "max_bytes" {
  description = "Raw (decoded, post-gzip) byte limit to validate against - AWS EC2's limit (16384) by default."
  type        = number
  default     = 16384
}

# --- Frequency-scoped scripts ---
# text/x-shellscript-per-boot/-per-instance/-per-once are real and functional
# (cc_scripts_per_boot/per_instance/per_once) but only documented via
# `cloud-init devel make-mime --list-types`, not the main docs page.
# text/cloud-boothook runs earlier and on every boot, as root - distinct from
# all three of the above.

variable "scripts" {
  description = "Frequency-scoped shell scripts, beyond the plain shell_scripts (text/x-shellscript). per_boot runs every boot; per_instance runs once per new instance id; per_once runs exactly once ever; boothook runs earliest of all, as root, every boot."
  type = object({
    per_boot     = optional(list(string), [])
    per_instance = optional(list(string), [])
    per_once     = optional(list(string), [])
    boothook     = optional(list(string), [])
  })
  default = {}
}

# --- Packages ---

variable "packages" {
  description = "Maps to cc_package_update_upgrade_install. install: plain names, [name, version] pairs, or manager-scoped {apt = [...], snap = [...]}. update/upgrade default false (never forced silently)."
  type = object({
    install            = optional(list(any), [])
    update             = optional(bool, false)
    upgrade            = optional(bool, false)
    reboot_if_required = optional(bool, false)
  })
  default = null
}

# --- Users and groups ---

variable "users" {
  description = "Maps to cc_users_groups's `users` key. Each entry is cloud-init's full user object shape (name required; groups/sudo/ssh_authorized_keys/etc. - see cloud-init's users_groups docs for the complete field set, passed through as-is via `extra`)."
  type = list(object({
    name                = string
    gecos               = optional(string)
    groups              = optional(list(string))
    shell               = optional(string)
    sudo                = optional(string)
    lock_passwd         = optional(bool, true)
    ssh_authorized_keys = optional(list(string))
    ssh_import_id       = optional(list(string))
    passwd              = optional(string)
    hashed_passwd       = optional(string)
    plain_text_passwd   = optional(string)
    system              = optional(bool, false)
    uid                 = optional(number)
    primary_group       = optional(string)
    homedir             = optional(string)
    no_create_home      = optional(bool, false)
    expiredate          = optional(string)
    extra               = optional(any, {})
  }))
  default = null
}

variable "groups" {
  description = "Maps to cc_users_groups's `groups` key - map of group name to a username or list of usernames to add to it."
  type        = map(list(string))
  default     = null
}

variable "ssh_authorized_keys" {
  description = "Maps to the top-level ssh_authorized_keys key (map of username to list of keys) - distinct from a users[] entry's own ssh_authorized_keys field. Use this for adding keys to a user this module isn't also creating (e.g. the AMI's default user)."
  type        = map(list(string))
  default     = {}
}

# --- Files ---

variable "files" {
  description = "Maps to cc_write_files. Keyed by destination path for a stable, deterministic order. permissions is an octal string (e.g. \"0644\"); encoding matches cloud-init's enum (text/plain, b64, gzip, gzip+base64, ...); defer delays the write until after users/packages are set up."
  type = map(object({
    content     = optional(string, "")
    owner       = optional(string, "root:root")
    permissions = optional(string, "0644")
    encoding    = optional(string, "text/plain")
    append      = optional(bool, false)
    defer       = optional(bool, false)
    source_uri  = optional(string)
  }))
  default = {}
}

# --- Commands ---

variable "commands" {
  description = "Maps to runcmd - runs once per instance, late in boot (Final stage), after packages/users/write_files. Each entry is a shell string or an argv-style list."
  type        = list(any)
  default     = []
}

variable "boot_commands" {
  description = "Maps to bootcmd - runs every boot, early (Network stage). Must be idempotent - cloud-init does not enforce this, it's the caller's responsibility."
  type        = list(any)
  default     = []
}

# --- Hostname / timezone ---

variable "hostname" {
  type    = string
  default = null
}

variable "fqdn" {
  type    = string
  default = null
}

variable "preserve_hostname" {
  type    = bool
  default = false
}

variable "timezone" {
  description = "IANA timezone name (e.g. \"America/Los_Angeles\", \"UTC\") - as found in /usr/share/zoneinfo."
  type        = string
  default     = null
}

# --- Mounts / disks ---

variable "mounts" {
  description = "Maps to cc_mounts - cloud-init's native fstab-tuple shape: [fs_spec, fs_file, fs_vfstype, fs_mntops, fs_freq, fs_passno], trailing fields omittable. Use a stable device identifier (UUID=.../LABEL=...), not a raw /dev/xvd* path - naming can differ between the guest OS and the EBS attachment on Nitro instances."
  type        = list(list(string))
  default     = []
}

variable "swap" {
  description = "Maps to the top-level swap key (a swapfile, not a swap partition). size/maxsize accept \"auto\" or a byte count/suffixed string (e.g. \"512M\")."
  type = object({
    filename = string
    size     = optional(string, "auto")
    maxsize  = optional(string)
  })
  default = null
}

variable "growpart" {
  type = object({
    mode                     = optional(string, "auto")
    devices                  = optional(list(string), ["/"])
    ignore_growroot_disabled = optional(bool, false)
  })
  default = null
}

variable "resize_rootfs" {
  description = "true, false, or \"noblock\" (resize in the background instead of blocking boot)."
  type        = string
  default     = null
}

variable "disk_setup" {
  description = "Maps to cc_disk_setup, keyed by device (or a device_aliases name). overwrite = true is destructive - cloud-init's own docs call this out explicitly."
  type = map(object({
    table_type = optional(string, "mbr")
    layout     = optional(any, false)
    overwrite  = optional(bool, false)
  }))
  default = {}
}

variable "fs_setup" {
  description = "Maps to cc_fs_setup. overwrite = true is destructive, same caveat as disk_setup."
  type = list(object({
    label      = optional(string)
    filesystem = string
    device     = string
    partition  = optional(string)
    overwrite  = optional(bool, false)
    extra_opts = optional(list(string), [])
  }))
  default = []
}

variable "device_aliases" {
  description = "Maps to the top-level device_aliases key - lets disk_setup/fs_setup/mounts reference a device by name instead of a raw path."
  type        = map(string)
  default     = {}
}

# --- SSH / CA certs ---

variable "ssh" {
  type = object({
    enabled              = optional(bool, true)
    emit_keys_to_console = optional(bool, true)
  })
  default = null
}

variable "ssh_genkeytypes" {
  description = "Host key types to generate, e.g. [\"rsa\", \"ecdsa\", \"ed25519\"]. Null uses cloud-init's own default set."
  type        = list(string)
  default     = null
}

variable "ssh_deletekeys" {
  description = "Delete the AMI's existing host keys before generating new ones - on by default upstream to avoid every instance from one AMI sharing host keys."
  type        = bool
  default     = null
}

variable "ca_certs" {
  type = object({
    trusted         = optional(list(string), [])
    remove_defaults = optional(bool, false)
  })
  default = null
}

# --- NTP ---

variable "ntp" {
  type = object({
    enabled    = optional(bool, true)
    ntp_client = optional(string)
    pools      = optional(list(string), [])
    servers    = optional(list(string), [])
  })
  default = null
}

# --- APT (Debian/Ubuntu) ---

variable "apt" {
  description = "Maps to cc_apt_configure - Debian/Ubuntu only, no-op on other distros. sources is keyed by an arbitrary source id."
  type = object({
    preserve_sources_list = optional(bool)
    disable_suites        = optional(list(string), [])
    sources = optional(map(object({
      source    = string
      keyid     = optional(string)
      key       = optional(string)
      keyserver = optional(string)
    })), {})
  })
  default = null
}

# --- Yum (RHEL family, including Amazon Linux) ---

variable "yum_repos" {
  description = "Maps to cc_yum_add_repo, keyed by repo id. Each needs exactly one of baseurl/metalink/mirrorlist (passed via extra) - other yum.conf keys (enabled, gpgcheck, ...) go in extra too."
  type = map(object({
    baseurl = optional(string)
    extra   = optional(any, {})
  }))
  default = {}
}

# --- Ansible ---

variable "ansible_pull" {
  description = "Native cc_ansible, git-based only (ansible-pull clones a repo and runs it - cloud-init's docs describe a remote URL, not a local path). For a playbook you already have locally or in S3, use ansible_playbooks instead, not this."
  type = list(object({
    url             = string
    playbook_names  = list(string)
    checkout        = optional(string)
    accept_host_key = optional(bool, true)
    full            = optional(bool)
    clean           = optional(bool)
    timeout         = optional(number)
  }))
  default = []
}

variable "ansible_install_method" {
  description = "How to install ansible-core before ansible_pull runs - \"distro\" or \"pip\". Only applies to ansible_pull (the native module); ansible_playbooks manages its own install separately, see ansible_core_install."
  type        = string
  default     = "distro"
}

# --- Power state / phone home / rsyslog ---

variable "power_state" {
  description = "Reboot/poweroff at the end of cloud-init's run. Opt-in only (null = do nothing)."
  type = object({
    mode      = string
    delay     = optional(string, "now")
    message   = optional(string)
    timeout   = optional(number, 30)
    condition = optional(string, "true")
  })
  default = null
}

variable "phone_home" {
  type = object({
    url   = string
    post  = optional(list(string), ["instance_id", "hostname", "fqdn"])
    tries = optional(number, 10)
  })
  default = null
}

variable "rsyslog" {
  type = object({
    configs = optional(list(string), [])
    remotes = optional(map(string), {})
  })
  default = null
}

# --- Artifact retrieval (S3 / HTTPS) ---
# Fetched on the instance at boot via its IAM instance profile - never via a
# Terraform data source at plan/apply time, never via static credentials.

variable "artifacts" {
  description = "Files to fetch onto the compute before ansible_playbooks/execution_steps run, using whatever identity it already has - never a static credential. source scheme picks the mechanism: s3://bucket/key (AWS IAM instance role via the aws CLI), gs://bucket/object (GCP attached service account via gcloud), azblob://account/container/blob (Azure Managed Identity via az, auth-mode login), or https://... (plain curl, no identity needed). Large content belongs here, not in cloud_config/shell_scripts - never embed big payloads as base64 in user_data. region/endpoint_url only apply to s3:// (endpoint_url also covers S3-compatible object storage, e.g. Hetzner Object Storage, MinIO)."
  type = list(object({
    source       = string
    destination  = string
    owner        = optional(string)
    permissions  = optional(string)
    sha256       = optional(string)
    region       = optional(string)
    endpoint_url = optional(string)
    extract      = optional(bool, false)
    extract_to   = optional(string)
  }))
  default = []
}

# --- Ansible playbooks already on disk (local write_files or artifacts-downloaded) ---
# Deliberately shell-based, not cc_ansible's setup_controller: this module
# can't guarantee setup_controller runs after an artifacts/runcmd download in
# the same boot, so a dependent download+run chain is kept in one ordered
# script instead of split across two cloud-init subsystems.

variable "ansible_playbooks" {
  type = list(object({
    path       = string
    inventory  = optional(string, "localhost,")
    connection = optional(string, "local")
    extra_vars = optional(map(string), {})
    tags       = optional(list(string), [])
    become     = optional(bool, true)
  }))
  default = []
}

variable "ansible_core_install" {
  description = "Install ansible-core via the distro package manager before running ansible_playbooks, if ansible-playbook isn't already on PATH."
  type        = bool
  default     = true
}

variable "execution_steps" {
  description = "Ordered shell commands run after artifacts are fetched and ansible_playbooks run - e.g. executing a downloaded .sh script, or starting a service."
  type = list(object({
    command = string
    cwd     = optional(string)
    env     = optional(map(string), {})
  }))
  default = []
}
