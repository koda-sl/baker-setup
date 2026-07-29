#!/usr/bin/env bash
set -uo pipefail

# Baker new-hire machine onboarding.
#
# One command to turn a stock Mac into a ready Baker workstation. It installs and
# verifies the whole toolchain, drives the GitHub + Vercel sign-ins, checks you
# actually have write access, and hands off to Conductor.
#
# Runs standalone (before the repo is even cloned):
#     curl -fsSL <public-url>/onboard.sh | bash
# Or from a checkout:
#     bash scripts/dev/onboard.sh
#
# Safe to run again any time — every step detects what's already there and skips it.
# Non-interactive (CI / re-verify): set BAKER_ONBOARD_YES=1 to skip the confirm prompt.
#
# This is the MACHINE layer only. The per-workspace provisioning (Convex project,
# live env pull, deploy, seed) is run automatically by Conductor via
# scripts/dev/conductor-setup.sh — you don't run that yourself. If a workspace ever
# looks off, run `pnpm dev:doctor` inside it.

# ── Constants (source of truth: scripts/lib/preflight.sh) ───────────────────
GITHUB_REPO="koda-sl/baker"
VERCEL_PROJECT="baker-dashboard"
REQUIRED_PNPM="10.28.0"
REQUIRED_NODE_MAJOR="22"
CONDUCTOR_URL="https://conductor.build"
# Copy of PREFLIGHT_CODEGRAPH_VERSION. This script runs standalone before the repo
# exists, so it cannot source preflight.sh. Drift is self-correcting rather than
# checked: ensure_codegraph re-installs on any version mismatch, so a stale pin
# here is fixed by the first workspace setup or dev:doctor run.
CODEGRAPH_VERSION="v1.5.0"
CODEGRAPH_INSTALL_URL="https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh"

# ── Logging (matches scripts/lib/preflight.sh) ──────────────────────────────
info()    { printf '\033[1;34m[info]\033[0m %s\n' "$1"; }
success() { printf '\033[1;32m[ok]\033[0m   %s\n' "$1"; }
warn()    { printf '\033[1;33m[warn]\033[0m %s\n' "$1"; }
error()   { printf '\033[1;31m[err]\033[0m  %s\n' "$1"; }
step()    { printf '\n\033[1;36m▸ %s\033[0m\n' "$1"; }

FAILED=0
fail() { error "$1"; FAILED=1; }

# ── macOS guard ─────────────────────────────────────────────────────────────
if [[ "$(uname -s)" != "Darwin" ]]; then
  error "This setup is for macOS only. Ask an admin for help on your platform."
  exit 1
fi

# Homebrew prefix differs by chip: Apple Silicon uses /opt/homebrew, Intel /usr/local.
if [[ "$(uname -m)" == "arm64" ]]; then
  BREW_PREFIX="/opt/homebrew"
else
  BREW_PREFIX="/usr/local"
fi

# The login shell profile we keep PATH/init lines in (zsh is the macOS default).
PROFILE="${BAKER_ONBOARD_PROFILE:-${HOME}/.zprofile}"

# Append a line to the profile only once (idempotent — no duplicate blocks, no vim).
ensure_profile_line() {
  local line=$1
  touch "$PROFILE"
  grep -qsF "$line" "$PROFILE" || printf '\n%s\n' "$line" >> "$PROFILE"
}

# All steps live inside main() so that when the script is PIPED into bash
# (curl … | bash), we can hand main() the real terminal on stdin. Piped bash
# reads the script itself from stdin — redirecting stdin mid-script would make
# bash read the remaining script from the keyboard (a silent hang). Defining
# main() first parses everything; only the last line executes it.
main() {

# ── Step 0: access checklist ────────────────────────────────────────────────
step "Before we start — access you must already have"
cat <<EOF
  Ask an admin to grant these BEFORE running setup (they can't be scripted):

    1. GitHub  — your account added to  ${GITHUB_REPO}  WITH WRITE ACCESS
                 (read-only can't open PRs or merge).
    2. Vercel  — access to the  ${VERCEL_PROJECT}  project (this is what pulls
                 your environment and Convex access).
    3. Claude  — an active  Claude Max  subscription (personal use is fine even
                 on a work email) — Conductor needs it to show Claude models.
    4. 1Password — access for any billing / shared credentials.
EOF
if [[ "${BAKER_ONBOARD_YES:-}" != "1" ]]; then
  printf '\nHave all four been granted? [y/N] '
  read -r reply
  case "$reply" in
    y | Y | yes | YES) ;;
    *)
      warn "Sort the access grants above first, then run this again."
      exit 1
      ;;
  esac
fi

# ── Step 1: Xcode Command Line Tools (gives you git) ────────────────────────
step "Command Line Tools (git)"
if xcode-select -p >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  success "git $(git --version | awk '{print $3}')"
else
  info "Installing Apple Command Line Tools (a system dialog will open)..."
  xcode-select --install >/dev/null 2>&1 || true
  warn "Finish the 'Command Line Tools' install in the dialog, then run this script again."
  exit 1
fi

# ── Step 2: Homebrew ────────────────────────────────────────────────────────
step "Homebrew"
if ! command -v brew >/dev/null 2>&1; then
  info "Installing Homebrew..."
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    || fail "Homebrew install failed — see https://brew.sh"
fi
# Put brew on PATH for this run and every future terminal.
if [[ -x "${BREW_PREFIX}/bin/brew" ]]; then
  ensure_profile_line "eval \"\$(${BREW_PREFIX}/bin/brew shellenv)\""
  eval "$(${BREW_PREFIX}/bin/brew shellenv)"
fi
if command -v brew >/dev/null 2>&1; then
  success "Homebrew $(brew --version | head -n1 | awk '{print $2}')"
else
  fail "Homebrew is not on your PATH. Open a new terminal and run this script again."
fi

brew_install() { # brew_install <formula> <cmd> [--cask]
  # <cmd> is the executable the formula provides — if it's already on PATH (e.g.
  # installed some other way), skip so we don't pull a duplicate copy via brew.
  local formula=$1 cmd=$2 cask=${3:-}
  command -v "$cmd" >/dev/null 2>&1 && return 0
  if [[ "$cask" == "--cask" ]]; then
    brew list --cask "$formula" >/dev/null 2>&1 && return 0
    info "Installing $formula..."
    brew install --cask "$formula" >/dev/null 2>&1 || return 1
  else
    brew list "$formula" >/dev/null 2>&1 && return 0
    info "Installing $formula..."
    brew install "$formula" >/dev/null 2>&1 || return 1
  fi
}

# ── Step 3: Node 22 (via nvm) ───────────────────────────────────────────────
# We pin Node 22 with nvm so a pre-existing Node 24 (the exact clash a new hire
# hit) never wins, and we write the nvm init lines to the profile ourselves so
# nobody has to hand-edit .zprofile.
step "Node ${REQUIRED_NODE_MAJOR}"
node_major() { node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0; }

if [[ "$(node_major)" == "$REQUIRED_NODE_MAJOR" ]]; then
  success "Node $(node --version)"
else
  export NVM_DIR="${HOME}/.nvm"
  if ! command -v brew >/dev/null 2>&1; then
    fail "Need Homebrew before Node — fix Homebrew above first."
  else
    brew_install nvm nvm || warn "nvm may already be present"
    mkdir -p "$NVM_DIR"
    ensure_profile_line "export NVM_DIR=\"\$HOME/.nvm\""
    ensure_profile_line "[ -s \"${BREW_PREFIX}/opt/nvm/nvm.sh\" ] && \\. \"${BREW_PREFIX}/opt/nvm/nvm.sh\""
    # shellcheck disable=SC1091
    [ -s "${BREW_PREFIX}/opt/nvm/nvm.sh" ] && \. "${BREW_PREFIX}/opt/nvm/nvm.sh"
    if command -v nvm >/dev/null 2>&1; then
      info "Installing Node ${REQUIRED_NODE_MAJOR} and selecting it with nvm..."
      nvm install "$REQUIRED_NODE_MAJOR" >/dev/null 2>&1
      nvm alias default "$REQUIRED_NODE_MAJOR" >/dev/null 2>&1
      nvm use "$REQUIRED_NODE_MAJOR" >/dev/null 2>&1
      # A Homebrew Node (e.g. the latest, in /opt/homebrew/bin) can sit ahead of
      # nvm on PATH and shadow it, so `nvm use` alone isn't enough in this script.
      # Pin nvm's Node ${REQUIRED_NODE_MAJOR} bin to the FRONT of PATH ourselves and
      # keep it there for the rest of the run. Brew's Node stays installed — we just
      # make sure nvm's version is the one that's used.
      nvm_node="$(nvm which "$REQUIRED_NODE_MAJOR" 2>/dev/null || true)"
      if [[ -n "$nvm_node" && -x "$nvm_node" ]]; then
        export PATH="$(dirname "$nvm_node"):$PATH"
      fi
      hash -r 2>/dev/null || true
    else
      fail "nvm didn't load. Open a new terminal and run this script again."
    fi
  fi
  if [[ "$(node_major)" == "$REQUIRED_NODE_MAJOR" ]]; then
    success "Node $(node --version) (via nvm)"
  else
    current_node="$(node --version 2>/dev/null || echo none)"
    fail "Node ${REQUIRED_NODE_MAJOR} isn't active through nvm (found ${current_node}). Open a new terminal and re-run."
  fi
fi

# ── Step 4: pnpm (via corepack — ships with Node) ───────────────────────────
step "pnpm ${REQUIRED_PNPM}"
if [[ "$(pnpm --version 2>/dev/null || true)" == "$REQUIRED_PNPM" ]]; then
  success "pnpm $REQUIRED_PNPM"
elif command -v corepack >/dev/null 2>&1; then
  info "Activating pnpm ${REQUIRED_PNPM} via corepack..."
  corepack enable >/dev/null 2>&1 || true
  corepack prepare "pnpm@${REQUIRED_PNPM}" --activate >/dev/null 2>&1 || true
  if [[ "$(pnpm --version 2>/dev/null || true)" == "$REQUIRED_PNPM" ]]; then
    success "pnpm $REQUIRED_PNPM"
  else
    fail "Couldn't activate pnpm ${REQUIRED_PNPM}. Run: corepack prepare pnpm@${REQUIRED_PNPM} --activate"
  fi
else
  fail "corepack not found — Node ${REQUIRED_NODE_MAJOR} isn't active yet. Fix Node above and re-run."
fi

# ── Step 5: GitHub CLI + auth + WRITE access ────────────────────────────────
step "GitHub CLI + write access"
if command -v brew >/dev/null 2>&1; then
  brew_install gh gh || fail "Couldn't install the GitHub CLI (gh)."
fi
if command -v gh >/dev/null 2>&1; then
  if ! gh auth status >/dev/null 2>&1; then
    info "Signing in to GitHub (a browser window opens)..."
    gh auth login || warn "GitHub sign-in didn't finish."
  fi
  if gh auth status >/dev/null 2>&1; then
    push=$(gh api "repos/${GITHUB_REPO}" --jq '.permissions.push' 2>/dev/null || echo "")
    if [[ "$push" == "true" ]]; then
      success "GitHub signed in with write access to ${GITHUB_REPO}"
    elif [[ "$push" == "false" ]]; then
      fail "Signed in, but you only have READ access to ${GITHUB_REPO}. Ask an admin for WRITE access."
    else
      fail "Signed in, but couldn't see ${GITHUB_REPO}. Ask an admin to add you (with write access)."
    fi
  else
    fail "Not signed in to GitHub. Run: gh auth login"
  fi
else
  fail "GitHub CLI (gh) is not installed."
fi

# ── Step 6: Vercel CLI + login ──────────────────────────────────────────────
# Sign-in only. We deliberately do NOT run `vercel link` here: this is a from-zero
# machine bootstrap and the repo doesn't exist yet. Linking (writing
# .vercel/project.json for the ${VERCEL_PROJECT} project) happens automatically
# inside every workspace — Conductor's setup calls preflight.sh `ensure_vercel_link`,
# which also pulls your env. Nothing to link by hand.
step "Vercel CLI + sign-in"
if command -v brew >/dev/null 2>&1; then
  brew_install vercel-cli vercel || fail "Couldn't install the Vercel CLI."
fi
if command -v vercel >/dev/null 2>&1; then
  if ! vercel whoami >/dev/null 2>&1; then
    info "Signing in to Vercel (browser SSO — pick your work email)..."
    vercel login || warn "Vercel sign-in didn't finish."
  fi
  if vercel whoami >/dev/null 2>&1; then
    success "Vercel signed in as $(vercel whoami 2>/dev/null)"
    info "No 'vercel link' needed — Conductor links the ${VERCEL_PROJECT} project and pulls your environment automatically."
  else
    fail "Not signed in to Vercel. Run: vercel login"
  fi
else
  fail "Vercel CLI is not installed."
fi

# ── Step 7: agent-browser (UI verification) ─────────────────────────────────
step "agent-browser (UI verification)"
if command -v agent-browser >/dev/null 2>&1; then
  success "agent-browser present"
elif command -v npm >/dev/null 2>&1; then
  info "Installing agent-browser..."
  npm install -g agent-browser >/dev/null 2>&1 \
    && agent-browser install >/dev/null 2>&1 \
    && success "agent-browser installed" \
    || fail "Couldn't install agent-browser. Run: npm install -g agent-browser && agent-browser install"
else
  fail "npm not found — Node ${REQUIRED_NODE_MAJOR} isn't active. Fix Node above and re-run."
fi

# ── Step 8: codegraph (agent code index) ────────────────────────────────────
# Machine layer: one binary in $HOME shared by every workspace. The per-workspace
# index is built by conductor-setup.sh, and the MCP server is wired by the repo's
# .mcp.json — so we deliberately do NOT run `codegraph install`, which would
# rewrite the repo's CLAUDE.md/AGENTS.md and your global agent config.
#
# The real reason this belongs in onboarding rather than only in setup: the
# installer drops the binary in ~/.local/bin, which is NOT on a stock macOS PATH
# (see /etc/paths). Only this script writes the profile, so only this script can
# make `codegraph …` work in a plain terminal.
#
# Optional tooling — a warn, never a fail: without it agents fall back to plain search.
step "codegraph (agent code index)"
ensure_profile_line 'export PATH="$HOME/.local/bin:$PATH"'
export PATH="$HOME/.local/bin:$PATH"
if command -v codegraph >/dev/null 2>&1; then
  success "codegraph $(codegraph version 2>/dev/null || echo present)"
else
  info "Installing codegraph ${CODEGRAPH_VERSION}..."
  curl -fsSL "$CODEGRAPH_INSTALL_URL" | CODEGRAPH_VERSION="$CODEGRAPH_VERSION" sh >/dev/null 2>&1 || true
  hash -r 2>/dev/null || true
  if command -v codegraph >/dev/null 2>&1; then
    success "codegraph ${CODEGRAPH_VERSION} installed"
  else
    warn "Couldn't install codegraph — agents fall back to plain search. Your workspace will retry."
  fi
fi

# ── Step 9: Claude Code (Conductor needs it for Claude models) ──────────────
step "Claude Code"
if command -v claude >/dev/null 2>&1; then
  success "Claude Code present"
elif command -v brew >/dev/null 2>&1; then
  brew_install claude-code claude --cask \
    && success "Claude Code installed" \
    || fail "Couldn't install Claude Code. Run: brew install --cask claude-code"
else
  fail "Need Homebrew to install Claude Code."
fi

# ── Step 10: Conductor app ──────────────────────────────────────────────────
# Conductor is a GUI app (no CLI binary), so we detect the .app bundle rather than
# a command. Cask: https://formulae.brew.sh/cask/conductor
step "Conductor"
if [[ ! -d "/Applications/Conductor.app" ]] && command -v brew >/dev/null 2>&1; then
  info "Installing Conductor..."
  brew install --cask conductor >/dev/null 2>&1 || true
fi
if [[ -d "/Applications/Conductor.app" ]]; then
  success "Conductor is installed"
  info "Open it, sign in with GitHub, then 'Open GitHub Project' → clone ${GITHUB_REPO}."
else
  warn "Couldn't install Conductor automatically. Download it from ${CONDUCTOR_URL}, then:"
  warn "  • open it and sign in with your GitHub account"
  warn "  • use 'Open GitHub Project' to clone ${GITHUB_REPO}"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
step "Summary"
report() { # report <label> <value-or-empty>
  if [[ -n "$2" ]]; then success "$1: $2"; else warn "$1: not ready"; fi
}
# Node must be exactly v22 — a wrong major is "not ready", not merely present.
if [[ "$(node_major)" == "$REQUIRED_NODE_MAJOR" ]]; then
  report "Node" "$(node --version 2>/dev/null)"
else
  report "Node" ""
fi
report "pnpm"          "$(pnpm --version 2>/dev/null)"
report "git"           "$(git --version 2>/dev/null | awk '{print $3}')"
report "GitHub CLI"    "$(command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && echo 'signed in' || true)"
report "Vercel"        "$(command -v vercel >/dev/null 2>&1 && vercel whoami 2>/dev/null || true)"
report "agent-browser" "$(command -v agent-browser >/dev/null 2>&1 && echo 'installed' || true)"
report "codegraph"     "$(command -v codegraph >/dev/null 2>&1 && echo 'installed' || true)"
report "Claude Code"   "$(command -v claude >/dev/null 2>&1 && echo 'installed' || true)"
report "Conductor"     "$([[ -d /Applications/Conductor.app ]] && echo 'installed' || true)"

echo ""
if [[ "$FAILED" -eq 0 ]]; then
  success "Your Mac is ready. 🎉"
  cat <<EOF

Your machine and accounts are set up. You will NOT clone the repo or run any
'vercel link' / setup commands yourself — Conductor does all of that for you.

Do exactly this, in order:

  STEP 1 — Open Conductor
     • Open the Conductor app (installed above; from Applications if needed).
     • Sign in with the SAME GitHub account you just authorized.

  STEP 2 — Add the project (only the first time)
     • Click "Open GitHub Project".
     • Choose  ${GITHUB_REPO}  and let Conductor clone it.
       (Conductor picks and manages the folder itself — you don't choose a path.)

  STEP 3 — Create a workspace and let it build
     • Click "New Workspace" and give it any name.
     • Conductor now runs the setup automatically: it links Vercel, pulls your
       environment, provisions the database, and starts the app. Just wait.
     • When it finishes you'll see:
         ✅ Workspace ready — the dashboard will open at http://localhost:3100

  IF A WORKSPACE LOOKS STUCK OR BROKEN
     • Open the workspace terminal and run:  pnpm dev:doctor
       It checks everything and tells you, in plain words, the one thing to fix.

Tip: open a fresh terminal window before you start, so the tools installed above
are picked up everywhere.
EOF
  exit 0
fi

error "Some steps need attention. Do this:"
warn "  1. Read each  [err]  line above — every one tells you exactly what to fix."
warn "  2. Open a NEW terminal window (so the tools just installed are on your PATH)."
warn "  3. Run this script again — already-done steps are skipped automatically."
exit 1

}

# ── Entry point ─────────────────────────────────────────────────────────────
# When piped (curl … | bash), stdin is the script — give main() the real
# terminal instead so prompts (y/N, gh auth login, vercel login) work.
# The subshell probe actually OPENS /dev/tty: `-r` alone lies when there is no
# controlling terminal (e.g. CI), where the open fails with ENXIO.
if [[ ! -t 0 ]] && (exec </dev/tty) 2>/dev/null; then
  main </dev/tty
else
  main
fi
