locals {
  # Every *_cfg below is one object literal with a fixed, unconditional set
  # of top-level keys - values are null when unset, never omitted. A
  # ternary between differently-shaped objects ({} vs {key=...}) breaks
  # Terraform's type unification ("inconsistent conditional result types");
  # null unifies with anything, so nulling a value is safe where omitting
  # a key is not. Nulls are stripped once, at the very end, from the fully
  # merged result.

  packages_cfg = {
    packages                   = var.packages != null && length(var.packages.install) > 0 ? var.packages.install : null
    package_update             = var.packages != null ? var.packages.update : null
    package_upgrade            = var.packages != null ? var.packages.upgrade : null
    package_reboot_if_required = var.packages != null ? var.packages.reboot_if_required : null
  }

  users_list = var.users == null ? null : [
    for u in var.users : merge(
      { name = u.name },
      {
        for k, v in {
          gecos               = u.gecos
          groups              = u.groups
          shell               = u.shell
          sudo                = u.sudo
          lock_passwd         = u.lock_passwd
          ssh_authorized_keys = u.ssh_authorized_keys
          ssh_import_id       = u.ssh_import_id
          passwd              = u.passwd
          hashed_passwd       = u.hashed_passwd
          plain_text_passwd   = u.plain_text_passwd
          system              = u.system
          uid                 = u.uid
          primary_group       = u.primary_group
          homedir             = u.homedir
          no_create_home      = u.no_create_home
          expiredate          = u.expiredate
        } : k => v if v != null
      },
      u.extra,
    )
  ]

  users_cfg  = { users = local.users_list }
  groups_cfg = { groups = var.groups }

  ssh_authorized_keys_cfg = {
    ssh_authorized_keys = length(var.ssh_authorized_keys) > 0 ? var.ssh_authorized_keys : null
  }

  # Systemd units: unit files + drop-ins via write_files (deferred to final
  # stage); daemon-reload/enable in runcmd run after the files exist.
  # Duplicate unit name+type errors at plan (duplicate key in the map below).

  # Runtime secrets (secrets variable): a generated oneshot service
  # materializes each entry at boot from a file already on the instance or
  # from a command's stdout - the values themselves never enter user-data or
  # state. The script is a 0700 file, not a unit ExecStart, so caller values
  # stay single-quoted in one shell layer (no nested systemd/shell quoting).
  secrets_active  = length(var.secrets) > 0
  secrets_service = "terraform-cloudinit-secrets.service"
  secrets_script  = "/usr/local/bin/terraform-cloudinit-secrets"

  secrets_script_lines = flatten([
    for s in var.secrets : concat(
      ["# secret: ${s.name}", "d=$(dirname ${local.shell_q[s.destination]})", "mkdir -p \"$d\""],
      s.command != null ? [
        "umask 077",
        "${s.command} > \"$d/.${s.name}.tmp\"",
        "install -m ${local.shell_q[s.permissions]} \"$d/.${s.name}.tmp\" ${local.shell_q[s.destination]}",
        ] : [
        "install -m ${local.shell_q[s.permissions]} ${local.shell_q[s.source_path]} ${local.shell_q[s.destination]}",
      ],
      s.owner != null ? ["chown ${local.shell_q[s.owner]} ${local.shell_q[s.destination]}"] : [],
      s.command != null ? ["rm -f \"$d/.${s.name}.tmp\""] : [],
    )
  ])

  secrets_script_content = local.secrets_active ? "#!/bin/sh\nset -eu\n" + join("\n", local.secrets_script_lines) + "\n" : null

  secrets_unit_content = local.secrets_active ? join("\n", [
    "[Unit]",
    "Description=Materialize runtime secrets (terraform-null-cloudinit)",
    "",
    "[Service]",
    "Type=oneshot",
    "RemainAfterExit=yes",
    "ExecStart=${local.secrets_script}",
    "",
    "[Install]",
    "WantedBy=multi-user.target",
    "",
  ]) : null

  secrets_file_entries = local.secrets_active ? [
    {
      path        = local.secrets_script
      content     = local.secrets_script_content
      permissions = "0700"
    },
    {
      path        = "/etc/systemd/system/${local.secrets_service}"
      content     = local.secrets_unit_content
      permissions = "0644"
    },
  ] : []

  systemd_file_entries = concat(
    flatten([
      for u in var.systemd_units : concat(
        [{
          path        = "/etc/systemd/system/${u.name}.${u.type}"
          content     = u.content
          permissions = "0644"
        }],
        [for d in sort(keys(u.dropins)) : {
          path        = "/etc/systemd/system/${u.name}.${u.type}.d/${d}"
          content     = u.dropins[d]
          permissions = "0644"
        }],
      )
    ]),
    local.secrets_file_entries,
  )

  systemd_files = {
    for e in local.systemd_file_entries : e.path => {
      content     = e.content
      owner       = "root:root"
      permissions = e.permissions
      encoding    = "text/plain"
      append      = false
      defer       = true
      source_uri  = null
    }
  }

  # merge() silently lets the later argument win on duplicate keys, so the
  # overlap is checked explicitly (same policy as cloud_config vs typed
  # helpers): one mechanism per path.
  systemd_files_conflict = setintersection(
    toset(keys(local.systemd_files)),
    toset(keys(var.files)),
  )

  files_all = merge(var.files, local.systemd_files)

  files_list = [
    for path in sort(keys(local.files_all)) : merge(
      { path = path },
      {
        for k, v in {
          content     = local.files_all[path].content
          owner       = local.files_all[path].owner
          permissions = local.files_all[path].permissions
          encoding    = local.files_all[path].encoding
          append      = local.files_all[path].append
          defer       = local.files_all[path].defer
        } : k => v if v != null
      },
      local.files_all[path].source_uri != null ? { source = { uri = local.files_all[path].source_uri } } : {},
    )
  ]
  write_files_cfg = { write_files = length(local.files_list) > 0 ? local.files_list : null }

  # "--" keeps names starting with a hyphen from being parsed as options.
  systemd_runcmd = (length(var.systemd_units) == 0 && !local.secrets_active) ? [] : concat(
    ["systemctl daemon-reload"],
    [for u in var.systemd_units : "systemctl enable -- ${u.name}.${u.type}" if u.enabled],
    local.secrets_active ? ["systemctl enable -- ${local.secrets_service}"] : [],
  )

  # systemd daemon-reload/enable lines run before var.commands.
  runcmd_all = concat(local.systemd_runcmd, var.commands)

  commands_cfg      = { runcmd = length(local.runcmd_all) > 0 ? local.runcmd_all : null }
  boot_commands_cfg = { bootcmd = length(var.boot_commands) > 0 ? var.boot_commands : null }

  hostname_cfg = {
    hostname          = var.hostname
    fqdn              = var.fqdn
    preserve_hostname = var.preserve_hostname ? true : null
  }

  timezone_cfg = { timezone = var.timezone }

  mounts_cfg = { mounts = length(var.mounts) > 0 ? var.mounts : null }

  swap_cfg = {
    swap = var.swap == null ? null : {
      for k, v in var.swap : k => v if v != null
    }
  }

  growpart_cfg = {
    growpart = var.growpart == null ? null : {
      for k, v in var.growpart : k => v if v != null
    }
  }

  resize_rootfs_cfg = { resize_rootfs = var.resize_rootfs }

  disk_setup_cfg = {
    disk_setup = length(var.disk_setup) > 0 ? { for k, v in var.disk_setup : k => v } : null
  }

  fs_setup_cfg = {
    fs_setup = length(var.fs_setup) > 0 ? [
      for f in var.fs_setup : { for k, v in f : k => v if v != null }
    ] : null
  }

  device_aliases_cfg = { device_aliases = length(var.device_aliases) > 0 ? var.device_aliases : null }

  ssh_cfg             = { ssh = var.ssh }
  ssh_genkeytypes_cfg = { ssh_genkeytypes = var.ssh_genkeytypes }
  ssh_deletekeys_cfg  = { ssh_deletekeys = var.ssh_deletekeys }

  ca_certs_cfg = {
    ca_certs = var.ca_certs == null ? null : {
      for k, v in var.ca_certs : k => v if v != null && v != []
    }
  }

  ntp_cfg = {
    ntp = var.ntp == null ? null : {
      for k, v in {
        enabled    = var.ntp.enabled
        ntp_client = var.ntp.ntp_client
        pools      = length(var.ntp.pools) > 0 ? var.ntp.pools : null
        servers    = length(var.ntp.servers) > 0 ? var.ntp.servers : null
      } : k => v if v != null
    }
  }

  apt_cfg = {
    apt = var.apt == null ? null : {
      for k, v in {
        preserve_sources_list = var.apt.preserve_sources_list
        disable_suites        = length(var.apt.disable_suites) > 0 ? var.apt.disable_suites : null
        sources = length(var.apt.sources) > 0 ? {
          for id, s in var.apt.sources : id => { for k, v in s : k => v if v != null }
        } : null
      } : k => v if v != null
    }
  }

  yum_repos_cfg = {
    yum_repos = length(var.yum_repos) > 0 ? {
      for id, r in var.yum_repos : id => merge(
        r.baseurl != null ? { baseurl = r.baseurl } : {},
        r.extra,
      )
    } : null
  }

  ansible_cfg = {
    ansible = length(var.ansible_pull) == 0 ? null : {
      install_method = var.ansible_install_method
      pull = [
        for p in var.ansible_pull : { for k, v in p : k => v if v != null }
      ]
    }
  }

  power_state_cfg = {
    power_state = var.power_state == null ? null : {
      for k, v in var.power_state : k => v if v != null
    }
  }

  phone_home_cfg = {
    phone_home = var.phone_home == null ? null : {
      for k, v in var.phone_home : k => v if v != null
    }
  }

  rsyslog_cfg = {
    rsyslog = var.rsyslog == null ? null : {
      for k, v in var.rsyslog : k => v if v != null
    }
  }

  generated_cloud_config_raw = merge(
    local.packages_cfg,
    local.users_cfg,
    local.groups_cfg,
    local.ssh_authorized_keys_cfg,
    local.write_files_cfg,
    local.commands_cfg,
    local.boot_commands_cfg,
    local.hostname_cfg,
    local.timezone_cfg,
    local.mounts_cfg,
    local.swap_cfg,
    local.growpart_cfg,
    local.resize_rootfs_cfg,
    local.disk_setup_cfg,
    local.fs_setup_cfg,
    local.device_aliases_cfg,
    local.ssh_cfg,
    local.ssh_genkeytypes_cfg,
    local.ssh_deletekeys_cfg,
    local.ca_certs_cfg,
    local.ntp_cfg,
    local.apt_cfg,
    local.yum_repos_cfg,
    local.ansible_cfg,
    local.power_state_cfg,
    local.phone_home_cfg,
    local.rsyslog_cfg,
  )

  generated_cloud_config = {
    for k, v in local.generated_cloud_config_raw : k => v if v != null
  }

  # The only real conflict risk is a key set by BOTH a typed helper and the
  # raw cloud_config escape hatch - silently letting one win would hide a
  # caller mistake, so this is a hard error instead (see the precondition
  # on cloud_config_conflict_check below).
  cloud_config_overlap = var.cloud_config == null ? [] : setintersection(
    toset(keys(local.generated_cloud_config)),
    toset(keys(var.cloud_config)),
  )

  cloud_config_merged = merge(local.generated_cloud_config, var.cloud_config != null ? var.cloud_config : {})
}

resource "terraform_data" "cloud_config_conflict_check" {
  count = length(local.generated_cloud_config) > 0 || var.cloud_config != null ? 1 : 0

  input = true

  lifecycle {
    precondition {
      condition     = length(local.cloud_config_overlap) == 0
      error_message = "cloud_config sets key(s) [${join(", ", local.cloud_config_overlap)}] that a typed helper variable also sets - pick one mechanism per key, don't set both."
    }
    precondition {
      condition     = length(local.systemd_files_conflict) == 0
      error_message = "files and systemd_units both define file(s) [${join(", ", local.systemd_files_conflict)}] - pick one mechanism per path."
    }
  }
}
