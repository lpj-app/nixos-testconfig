#!/bin/sh
# SSH_ASKPASS helper: secrets come from the job's environment, never argv or the log.
# $1 is ssh's prompt; jump host prompts name its key path or user@host.
case "$1" in
  *passphrase*"${DEPLOY_JUMP_KEY:-/nonexistent/}"*) printf '%s\n' "$DEPLOY_JUMP_PASSPHRASE" ;;
  *"${DEPLOY_JUMP:-/nonexistent/}'s password"*) printf '%s\n' "$DEPLOY_JUMP_PASSWORD" ;;
  *) printf '%s\n' "$DEPLOY_SSH_PASSWORD" ;;
esac
