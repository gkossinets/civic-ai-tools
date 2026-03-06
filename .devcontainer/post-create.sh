#!/bin/bash
#
# Codespaces post-create setup script (fault-tolerant)
#
# Unlike scripts/setup.sh (which uses set -e for local dev), this script
# uses set +e so that a single failure (network blip, npm timeout) doesn't
# prevent the Codespace from opening. Each step has a timeout wrapper.
#

set +e  # Continue on errors — the Codespace must always open

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PROJECT_DIR="/workspaces/civic-ai-tools"
MCP_SERVERS_DIR="$PROJECT_DIR/.mcp-servers"
OPENGOV_DIR="$MCP_SERVERS_DIR/opengov-mcp-server"

# Prevent git from prompting for credentials (hangs in Codespaces)
export GIT_TERMINAL_PROMPT=0

echo -e "${BLUE}"
echo "========================================"
echo "  Civic AI Tools - Codespace Setup"
echo "========================================"
echo -e "${NC}"

WARNINGS=()

# ──────────────────────────────────────────
# Step 1: Clone OpenGov MCP server
# ──────────────────────────────────────────
echo -e "\n${BLUE}>>> Step 1/4: Cloning OpenGov MCP server...${NC}"

mkdir -p "$MCP_SERVERS_DIR"

if [ -d "$OPENGOV_DIR/.git" ]; then
    echo -e "${GREEN}[OK]${NC} Already cloned"
else
    if timeout --kill-after=10 90 git clone --depth 1 https://github.com/npstorey/opengov-mcp-server.git "$OPENGOV_DIR" 2>&1; then
        echo -e "${GREEN}[OK]${NC} Cloned successfully"
    else
        echo -e "${RED}[FAIL]${NC} git clone failed (network issue?)"
        WARNINGS+=("OpenGov MCP server failed to clone — run ./scripts/setup.sh to retry")
    fi
fi

# ──────────────────────────────────────────
# Step 2: Build OpenGov MCP server
# ──────────────────────────────────────────
echo -e "\n${BLUE}>>> Step 2/4: Building OpenGov MCP server...${NC}"

if [ -d "$OPENGOV_DIR" ]; then
    cd "$OPENGOV_DIR"

    if timeout --kill-after=10 120 npm install --no-fund --no-audit 2>&1; then
        echo -e "${GREEN}[OK]${NC} npm install succeeded"
    else
        echo -e "${RED}[FAIL]${NC} npm install failed"
        WARNINGS+=("npm install failed for OpenGov MCP — run ./scripts/setup.sh to retry")
    fi

    if [ -f "$OPENGOV_DIR/node_modules/.package-lock.json" ]; then
        if timeout --kill-after=10 60 npm run build 2>&1; then
            echo -e "${GREEN}[OK]${NC} Build succeeded"
        else
            echo -e "${RED}[FAIL]${NC} npm run build failed"
            WARNINGS+=("OpenGov MCP build failed — run ./scripts/setup.sh to retry")
        fi
    fi

    cd "$PROJECT_DIR"
else
    echo -e "${YELLOW}[SKIP]${NC} OpenGov directory not found (clone failed earlier)"
fi

# ──────────────────────────────────────────
# Step 3: Install datacommons-mcp
# ──────────────────────────────────────────
echo -e "\n${BLUE}>>> Step 3/4: Installing datacommons-mcp...${NC}"

if command -v datacommons-mcp &>/dev/null; then
    echo -e "${GREEN}[OK]${NC} Already installed"
else
    if command -v uv &>/dev/null; then
        if timeout --kill-after=10 90 uv tool install datacommons-mcp 2>&1; then
            echo -e "${GREEN}[OK]${NC} Installed via uv"
        else
            echo -e "${YELLOW}[WARN]${NC} uv install failed, trying pip..."
            if timeout --kill-after=10 90 pip3 install datacommons-mcp 2>&1; then
                echo -e "${GREEN}[OK]${NC} Installed via pip"
            else
                echo -e "${RED}[FAIL]${NC} datacommons-mcp installation failed"
                WARNINGS+=("datacommons-mcp failed to install — run ./scripts/setup.sh to retry")
            fi
        fi
    else
        if timeout --kill-after=10 90 pip3 install datacommons-mcp 2>&1; then
            echo -e "${GREEN}[OK]${NC} Installed via pip"
        else
            echo -e "${RED}[FAIL]${NC} datacommons-mcp installation failed"
            WARNINGS+=("datacommons-mcp failed to install — run ./scripts/setup.sh to retry")
        fi
    fi
fi

# ──────────────────────────────────────────
# Step 4: Generate MCP config files
# ──────────────────────────────────────────
echo -e "\n${BLUE}>>> Step 4/4: Generating MCP configuration...${NC}"

# API keys come from (in priority order):
#   1. Codespaces Secrets (auto-injected as env vars)
#   2. .env file in the project
# If neither is set, Socrata works without a token (just rate-limited),
# and Data Commons is skipped entirely.

SOCRATA_TOKEN="${SOCRATA_APP_TOKEN:-}"
DC_KEY="${DC_API_KEY:-}"

# Fall back to .env file if Codespaces Secrets aren't set
if [ -z "$SOCRATA_TOKEN" ] || [ -z "$DC_KEY" ]; then
    if [ -f "$PROJECT_DIR/.env" ]; then
        echo "Loading API keys from .env..."
        set -a
        source "$PROJECT_DIR/.env" 2>/dev/null || true
        set +a
        [ -z "$SOCRATA_TOKEN" ] && SOCRATA_TOKEN="${SOCRATA_APP_TOKEN:-}"
        [ -z "$DC_KEY" ] && DC_KEY="${DC_API_KEY:-}"
    fi
fi

DATACOMMONS_PATH=$(command -v datacommons-mcp 2>/dev/null || echo "")

# Determine which servers to include
INCLUDE_OPENGOV=false
INCLUDE_DATACOMMONS=false

if [ -f "$OPENGOV_DIR/dist/index.js" ]; then
    INCLUDE_OPENGOV=true
else
    echo -e "${YELLOW}[SKIP]${NC} OpenGov server not built — excluding from MCP config"
    WARNINGS+=("OpenGov MCP not available (build missing)")
fi

if [ -n "$DATACOMMONS_PATH" ] && [ -n "$DC_KEY" ]; then
    INCLUDE_DATACOMMONS=true
elif [ -z "$DATACOMMONS_PATH" ]; then
    echo -e "${YELLOW}[SKIP]${NC} datacommons-mcp not installed — excluding from MCP config"
elif [ -z "$DC_KEY" ]; then
    echo -e "${YELLOW}[SKIP]${NC} No DC_API_KEY found — excluding Data Commons from MCP config"
    echo -e "         Set it via Codespaces Secrets or .env to enable Data Commons"
fi

# Build .vscode/mcp.json dynamically
mkdir -p "$PROJECT_DIR/.vscode"
{
    echo '{'
    echo '  "servers": {'

    NEED_COMMA=false

    if $INCLUDE_OPENGOV; then
        $NEED_COMMA && echo ','
        echo '    "opengov": {'
        echo '      "type": "stdio",'
        echo '      "command": "node",'
        echo "      \"args\": [\"\${workspaceFolder}/.mcp-servers/opengov-mcp-server/dist/index.js\", \"--stdio\"],"
        echo '      "env": {'
        echo '        "DEFAULT_DOMAIN": "data.cityofnewyork.us",'
        if [ -n "$SOCRATA_TOKEN" ]; then
            echo "        \"SOCRATA_APP_TOKEN\": \"$SOCRATA_TOKEN\","
        fi
        echo '        "CACHE_ENABLED": "true",'
        echo '        "LOG_LEVEL": "info"'
        echo '      }'
        echo -n '    }'
        NEED_COMMA=true
    fi

    if $INCLUDE_DATACOMMONS; then
        $NEED_COMMA && echo ','
        echo '    "data-commons": {'
        echo '      "type": "stdio",'
        echo "      \"command\": \"$DATACOMMONS_PATH\","
        echo '      "args": ["serve", "--skip-api-key-validation", "stdio"],'
        echo '      "env": {'
        echo "        \"DC_API_KEY\": \"$DC_KEY\""
        echo '      }'
        echo -n '    }'
        NEED_COMMA=true
    fi

    echo ''
    echo '  }'
    echo '}'
} > "$PROJECT_DIR/.vscode/mcp.json"

if $INCLUDE_OPENGOV || $INCLUDE_DATACOMMONS; then
    echo -e "${GREEN}[OK]${NC} Created .vscode/mcp.json"
    $INCLUDE_OPENGOV && echo -e "       ${GREEN}✓${NC} OpenGov MCP (Socrata${SOCRATA_TOKEN:+ — API key set}${SOCRATA_TOKEN:- — no key, rate-limited})"
    $INCLUDE_DATACOMMONS && echo -e "       ${GREEN}✓${NC} Data Commons MCP"
else
    echo -e "${YELLOW}[WARN]${NC} No MCP servers available — .vscode/mcp.json is empty"
fi

# Generate .mcp.json (for Claude Code CLI, if used in Codespace)
{
    echo '{'
    echo '  "mcpServers": {'

    NEED_COMMA=false

    if $INCLUDE_OPENGOV; then
        $NEED_COMMA && echo ','
        echo '    "opengov": {'
        echo '      "type": "stdio",'
        echo '      "command": "node",'
        echo "      \"args\": [\".mcp-servers/opengov-mcp-server/dist/index.js\", \"--stdio\"],"
        echo '      "env": {'
        echo '        "DEFAULT_DOMAIN": "data.cityofnewyork.us",'
        if [ -n "$SOCRATA_TOKEN" ]; then
            echo "        \"SOCRATA_APP_TOKEN\": \"$SOCRATA_TOKEN\","
        fi
        echo '        "CACHE_ENABLED": "true",'
        echo '        "LOG_LEVEL": "info"'
        echo '      }'
        echo -n '    }'
        NEED_COMMA=true
    fi

    if $INCLUDE_DATACOMMONS; then
        $NEED_COMMA && echo ','
        echo '    "data-commons": {'
        echo '      "type": "stdio",'
        echo "      \"command\": \"$DATACOMMONS_PATH\","
        echo '      "args": ["serve", "--skip-api-key-validation", "stdio"],'
        echo '      "env": {'
        echo "        \"DC_API_KEY\": \"$DC_KEY\""
        echo '      }'
        echo -n '    }'
        NEED_COMMA=true
    fi

    echo ''
    echo '  }'
    echo '}'
} > "$PROJECT_DIR/.mcp.json"
echo -e "${GREEN}[OK]${NC} Created .mcp.json"

# ──────────────────────────────────────────
# Done — print summary
# ──────────────────────────────────────────
echo ""
echo -e "${BLUE}========================================${NC}"

if [ ${#WARNINGS[@]} -eq 0 ]; then
    echo -e "${GREEN}  Setup completed successfully!${NC}"
else
    echo -e "${YELLOW}  Setup completed with warnings${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    for warn in "${WARNINGS[@]}"; do
        echo -e "  ${YELLOW}⚠${NC}  $warn"
    done
fi

echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${GREEN}NEXT STEPS:${NC}"
echo ""
echo "  1. Open Copilot Chat (sidebar chat icon or Ctrl+Shift+I)"
echo "  2. Switch to Agent mode (dropdown at the top of chat)"
echo "  3. Ask a question like: \"What are the top 311 complaint types in NYC?\""
echo ""
if [ -z "$SOCRATA_TOKEN" ] && [ -z "$DC_KEY" ]; then
    echo -e "${YELLOW}API KEYS:${NC}"
    echo ""
    echo "  No API keys detected. OpenGov works without a key (rate-limited)."
    echo "  For full access, set Codespaces Secrets in your repo settings:"
    echo "    → Settings → Secrets and variables → Codespaces"
    echo "    → Add SOCRATA_APP_TOKEN and/or DC_API_KEY"
    echo "    → Then rebuild the Codespace"
    echo ""
fi
echo -e "${YELLOW}TROUBLESHOOTING:${NC}"
echo ""
echo "  • \"Language model unavailable\" or Copilot not loading?"
echo "    → Ctrl+Shift+P → \"Developer: Reload Window\" (this is normal on first load)"
echo ""
echo "  • MCP tools not showing in chat?"
echo "    → Make sure you're in Agent mode, not Ask or Edit mode"
echo ""
echo "  • Setup failed partially?"
echo "    → Run: ./scripts/setup.sh"
echo ""
