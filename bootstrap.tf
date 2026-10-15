locals {
  # Shell-quoting (issue #1): every caller-controlled value spliced into the
  # generated bootstrap script is single-quoted via local.shell_q - inside
  # single quotes no character ($, `, \, ", ') can alter command structure.
  # Deliberately unquoted: execution_steps[].command and the raw script
  # variables - shell source by contract.

  s3_artifacts     = [for a in var.artifacts : a if startswith(a.source, "s3://")]
  gs_artifacts     = [for a in var.artifacts : a if startswith(a.source, "gs://")]
  azblob_artifacts = [for a in var.artifacts : a if startswith(a.source, "azblob://")]

  azblob_parts_by_source = {
    for a in local.azblob_artifacts : a.source => regex("^azblob://([^/]+)/([^/]+)/(.+)$", a.source)
  }

  # All values the bootstrap script interpolates, deduplicated - the
  # single-quoted form of each is precomputed in local.shell_q (lookup, not a
  # function call; Terraform has no user-defined functions).
  shell_quote_candidates = toset(flatten([
    [for a in var.artifacts : [for v in [a.source, a.destination, a.owner, a.permissions, a.sha256, a.region, a.endpoint_url, a.extract_to] : v if v != null]],
    [for src, parts in local.azblob_parts_by_source : parts],
    [for p in var.ansible_playbooks : [p.path, p.inventory, p.connection]],
    [for p in var.ansible_playbooks : join(",", p.tags) if length(p.tags) > 0],
    [for p in var.ansible_playbooks : join(" ", [for k, v in p.extra_vars : "${k}=${v}"]) if length(p.extra_vars) > 0],
    [for s in var.execution_steps : [for v in [s.cwd] : v if v != null]],
    [for s in var.execution_steps : values(s.env)],
  ]))

  shell_q = {
    for v in local.shell_quote_candidates : v => "'${replace(v, "'", "'\\''")}'"
  }

  # awscli ships in every mainstream distro's default package repo - a
  # simple conditional install is reliable. gcloud/az do not (they need a
  # vendor repo added first), so those paths fail with a clear message
  # instead of attempting a fragile multi-step install.
  aws_cli_bootstrap = length(local.s3_artifacts) == 0 ? [] : [
    "if ! command -v aws >/dev/null 2>&1; then",
    "  if command -v dnf >/dev/null 2>&1; then dnf install -y awscli",
    "  elif command -v yum >/dev/null 2>&1; then yum install -y awscli",
    "  elif command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y awscli",
    "  else echo 'artifacts: no supported package manager found to install aws-cli' >&2; exit 1",
    "  fi",
    "fi",
  ]

  gcloud_check = length(local.gs_artifacts) == 0 ? [] : [
    "if ! command -v gcloud >/dev/null 2>&1; then",
    "  echo 'artifacts: gs:// source requires the Google Cloud SDK (gcloud) pre-installed on this image - no reliable one-line install across distros, see https://cloud.google.com/sdk/docs/install' >&2",
    "  exit 1",
    "fi",
  ]

  az_cli_check = length(local.azblob_artifacts) == 0 ? [] : [
    "if ! command -v az >/dev/null 2>&1; then",
    "  echo 'artifacts: azblob:// source requires the Azure CLI (az) pre-installed on this image - no reliable one-line install across distros, see https://learn.microsoft.com/cli/azure/install-azure-cli' >&2",
    "  exit 1",
    "fi",
  ]

  cli_bootstrap = concat(local.aws_cli_bootstrap, local.gcloud_check, local.az_cli_check)

  # One ordered list of shell lines per artifact - fetch (S3/GCS/Azure Blob
  # via the compute's own attached identity, or HTTPS), verify, own, chmod,
  # optionally extract. Never a static credential in any of these - AWS IAM
  # instance role, GCP attached service account, Azure Managed Identity are
  # each picked up automatically by their respective CLI.
  artifact_lines = flatten([
    for a in var.artifacts : concat(
      ["mkdir -p \"$(dirname ${local.shell_q[a.destination]})\""],
      startswith(a.source, "s3://") ? [
        "aws s3 cp ${a.endpoint_url != null ? "--endpoint-url ${local.shell_q[a.endpoint_url]} " : ""}${a.region != null ? "--region ${local.shell_q[a.region]} " : ""}${local.shell_q[a.source]} ${local.shell_q[a.destination]}"
        ] : startswith(a.source, "gs://") ? [
        "gcloud storage cp ${local.shell_q[a.source]} ${local.shell_q[a.destination]}"
        ] : startswith(a.source, "azblob://") ? [
        "az storage blob download --auth-mode login --account-name ${local.shell_q[local.azblob_parts_by_source[a.source][0]]} --container-name ${local.shell_q[local.azblob_parts_by_source[a.source][1]]} --name ${local.shell_q[local.azblob_parts_by_source[a.source][2]]} --file ${local.shell_q[a.destination]}"
        ] : [
        "curl -fsSL -o ${local.shell_q[a.destination]} ${local.shell_q[a.source]}"
      ],
      a.sha256 != null ? ["printf '%s  %s\\n' ${local.shell_q[a.sha256]} ${local.shell_q[a.destination]} | sha256sum -c -"] : [],
      a.owner != null ? ["chown ${local.shell_q[a.owner]} ${local.shell_q[a.destination]}"] : [],
      a.permissions != null ? ["chmod ${local.shell_q[a.permissions]} ${local.shell_q[a.destination]}"] : [],
      a.extract ? [
        "EXTRACT_DIR=${a.extract_to != null ? local.shell_q[a.extract_to] : "$(dirname ${local.shell_q[a.destination]})"}",
        "mkdir -p \"$EXTRACT_DIR\"",
        "tar -xzf ${local.shell_q[a.destination]} -C \"$EXTRACT_DIR\"",
      ] : [],
    )
  ])

  ansible_core_bootstrap = length(var.ansible_playbooks) == 0 || !var.ansible_core_install ? [] : [
    "if ! command -v ansible-playbook >/dev/null 2>&1; then",
    "  if command -v dnf >/dev/null 2>&1; then dnf install -y ansible-core",
    "  elif command -v yum >/dev/null 2>&1; then yum install -y ansible",
    "  elif command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y ansible-core",
    "  else echo 'ansible_playbooks: no supported package manager found to install ansible-core' >&2; exit 1",
    "  fi",
    "fi",
  ]

  # extra_vars/env keys are validated as shell identifiers below; the joined
  # --extra-vars string is one shell word.
  ansible_playbook_lines = flatten([
    for p in var.ansible_playbooks : [
      join(" ", concat(
        ["ansible-playbook"],
        ["-i", local.shell_q[p.inventory]],
        ["-c", local.shell_q[p.connection]],
        p.become ? ["-b"] : [],
        length(p.tags) > 0 ? ["--tags", local.shell_q[join(",", p.tags)]] : [],
        length(p.extra_vars) > 0 ? ["--extra-vars", local.shell_q[join(" ", [for k, v in p.extra_vars : "${k}=${v}"])]] : [],
        [local.shell_q[p.path]],
      ))
    ]
  ])

  execution_step_lines = flatten([
    for s in var.execution_steps : concat(
      s.cwd != null ? ["cd ${local.shell_q[s.cwd]}"] : [],
      [join(" ", concat([for k, v in s.env : "${k}=${local.shell_q[v]}"], [s.command]))],
    )
  ])

  bootstrap_lines = concat(
    local.cli_bootstrap,
    local.artifact_lines,
    local.ansible_core_bootstrap,
    local.ansible_playbook_lines,
    local.execution_step_lines,
  )

  bootstrap_script = length(local.bootstrap_lines) == 0 ? null : join("\n", concat(
    ["#!/bin/bash", "set -euo pipefail"],
    local.bootstrap_lines,
  ))

  bootstrap_part = local.bootstrap_script == null ? [] : [{
    content_type = "text/x-shellscript"
    content      = local.bootstrap_script
    filename     = null
    merge_type   = null
  }]

  # Pure string/jsonencode construction, no cloud-provider provider required -
  # this module only renders user-data, it never provisions IAM/identity
  # resources itself. The caller attaches these to whatever identity the
  # compute actually runs as.
  s3_artifact_parts = [
    for a in local.s3_artifacts : regex("^s3://([^/]+)/(.+)$", a.source)
  ]

  aws_required_permissions = length(local.s3_artifact_parts) == 0 ? null : jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = [for p in local.s3_artifact_parts : "arn:aws:s3:::${p[0]}/${p[1]}"]
    }]
  })

  gcp_required_permissions = length(local.gs_artifacts) == 0 ? null : {
    role    = "roles/storage.objectViewer"
    objects = [for a in local.gs_artifacts : a.source]
  }

  azure_required_permissions = length(local.azblob_artifacts) == 0 ? null : {
    role  = "Storage Blob Data Reader"
    blobs = [for a in local.azblob_artifacts : "${local.azblob_parts_by_source[a.source][0]}/${local.azblob_parts_by_source[a.source][1]}/${local.azblob_parts_by_source[a.source][2]}"]
  }
}
