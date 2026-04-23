#!/usr/bin/env bash
set -euo pipefail

# CIS Level 1 Server hardening subset for Ubuntu/Debian
#
# Applies controls most likely to affect k3s/Kubernetes operation.
# This is NOT a full CIS benchmark — it's a smoke test to validate
# that Rathsted Foundations installs and runs on a hardened host.
#
# Controls applied (Ubuntu CIS Benchmark v3.0.0 references):
#   1.5.1  - Restrict core dumps
#   1.5.3  - Enable ASLR
#   3.1.1  - Disable unused network protocols (dccp, sctp, rds, tipc)
#   3.2.1  - Disable packet redirect sending
#   3.2.2  - Disable ICMP redirects
#   3.3.1  - Disable IPv6 router advertisements (if not needed)
#   4.2.4  - Set default umask to 027
#   5.2.x  - SSH hardening (subset)
#
# Controls deliberately NOT applied (k3s requires them):
#   3.2.1  - IP forwarding (net.ipv4.ip_forward=1) — required for pod networking
#   Kernel modules: overlay, br_netfilter — required for container networking

info() { echo "[cis-harden] $*"; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[cis-harden] Must run as root" >&2
  exit 1
fi

info "Applying CIS Level 1 Server hardening subset..."

# --- 1.5.1 Restrict core dumps ---
info "1.5.1 Restricting core dumps"
cat >> /etc/security/limits.conf <<'EOF'
# CIS 1.5.1 - Restrict core dumps
* hard core 0
EOF
echo 'fs.suid_dumpable = 0' > /etc/sysctl.d/60-cis-coredump.conf

# --- 1.5.3 Enable ASLR ---
info "1.5.3 Enabling ASLR"
echo 'kernel.randomize_va_space = 2' > /etc/sysctl.d/60-cis-aslr.conf

# --- 3.1.1 Disable unused network protocols ---
info "3.1.1 Disabling unused network protocols"
cat > /etc/modprobe.d/cis-protocols.conf <<'EOF'
install dccp /bin/true
install sctp /bin/true
install rds /bin/true
install tipc /bin/true
EOF

# --- 3.2.1 Disable packet redirect sending ---
# NOTE: We do NOT disable ip_forward — k3s requires it
info "3.2.1 Disabling packet redirect sending"
cat > /etc/sysctl.d/60-cis-network.conf <<'EOF'
# CIS 3.2.1 - Disable send redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
# CIS 3.2.2 - Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
# CIS 3.3.1 - Disable IPv6 router advertisements
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
# CIS 3.2.4 - Log martian packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
# CIS 3.2.5 - Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
EOF

# --- Apply sysctl changes ---
sysctl --system >/dev/null 2>&1 || true

# --- 4.2.4 Set restrictive umask ---
info "4.2.4 Setting default umask to 027"
if [[ -f /etc/login.defs ]]; then
  sed -i 's/^UMASK.*/UMASK\t\t027/' /etc/login.defs
fi

# --- 5.2.x SSH hardening ---
info "5.2.x Hardening SSH configuration"
if [[ -d /etc/ssh/sshd_config.d ]]; then
  cat > /etc/ssh/sshd_config.d/60-cis-hardening.conf <<'EOF'
# CIS SSH hardening subset
PermitRootLogin no
MaxAuthTries 4
PermitEmptyPasswords no
X11Forwarding no
AllowTcpForwarding no
MaxSessions 4
LoginGraceTime 60
ClientAliveInterval 300
ClientAliveCountMax 3
EOF
fi

# --- 5.4.1 Set password policies (if pam available) ---
info "5.4.1 Setting password expiration defaults"
if [[ -f /etc/login.defs ]]; then
  sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS\t365/' /etc/login.defs
  sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS\t1/' /etc/login.defs
  sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE\t7/' /etc/login.defs
fi

# --- Summary ---
info "CIS Level 1 hardening applied (subset)"
info "Controls skipped for k3s compatibility: ip_forward, overlay/br_netfilter modules"
info "This is a smoke test, not a full CIS audit"
