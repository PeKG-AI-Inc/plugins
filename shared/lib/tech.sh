#!/usr/bin/env bash
# PeKG TECH_PATTERNS library + detector (A24/A53/A100 ports).
# Source after config.sh.
#
# Pattern format: <name>|<grep -E regex>|<comma-separated search terms>
# Detection runs grep -iE against file content (small files only).

PEKG_TECH_PATTERNS=(
  'drizzle|from .[\x27"]drizzle-orm|import.*drizzle|drizzle,postgres-js,ORM'
  'clickhouse|from .[\x27"]@clickhouse|clickhouse.*client|clickhouse,ReplacingMergeTree,AggregatingMergeTree'
  'redis|from .[\x27"]ioredis|from .[\x27"]redis|new Redis\(|redis,connection pool,ioredis'
  'postgresql|from .[\x27"]pg[\x27"]|from .[\x27"]postgres[\x27"]|PostgreSQL|postgresql,postgres,connection'
  'auth|OAuth|from .[\x27"]jose[\x27"]|JWT|jsonwebtoken|OAuth,JWT,authentication,token'
  'better-auth|from .[\x27"]better-auth|better-auth,OAuth,authentication'
  'fastify|from .[\x27"]fastify|Fastify|fastify,middleware,bodyLimit'
  'express|from .[\x27"]express[\x27"]|express\(\)|express,middleware,cors'
  'hono|from .[\x27"]hono[\x27"]|new Hono\(|hono,middleware'
  'nextjs|from .[\x27"]next|NextResponse|getServerSideProps|nextjs,App Router,fetch caching'
  'react|from .[\x27"]react[\x27"]|useState|useEffect|react,hooks,state'
  'mcp|@modelcontextprotocol|MCP|StreamableHTTP|MCP,session,StreamableHTTP'
  'temporal|from .[\x27"]@temporalio|Temporal\.|temporal,workflow,activity'
  'tailwind|tailwindcss|@tailwind|tailwind,utility-first,css'
  'fastapi|from fastapi|FastAPI\(|fastapi,python,async'
)

# pekg_detect_techs <file_path>
# Echoes detected tech names (one per line), deduped.
pekg_detect_techs() {
  local file="$1"
  [ -f "$file" ] || return 0
  # Skip large files (>200KB) to keep hook fast.
  local size
  size=$(wc -c < "$file" 2>/dev/null || echo 0)
  [ "$size" -gt 204800 ] && return 0

  local content
  content=$(head -c 204800 "$file" 2>/dev/null || true)
  [ -z "$content" ] && return 0

  local entry name regex
  for entry in "${PEKG_TECH_PATTERNS[@]}"; do
    name="${entry%%|*}"
    local rest="${entry#*|}"
    # The regex is everything between the first | and the last | (search terms).
    regex="${rest%|*}"
    if printf '%s' "$content" | grep -iqE "$regex" 2>/dev/null; then
      echo "$name"
    fi
  done | sort -u
}

# pekg_search_terms_for <tech-name>
# Echoes comma-joined search terms for a detected tech (for proactive context).
pekg_search_terms_for() {
  local target="$1"
  local entry name terms
  for entry in "${PEKG_TECH_PATTERNS[@]}"; do
    name="${entry%%|*}"
    if [ "$name" = "$target" ]; then
      terms="${entry##*|}"
      printf '%s' "$terms"
      return 0
    fi
  done
}
