#!/bin/bash

brew install --cask swiftbar
brew install ccusage
brew install jq

chmod +x "$(dirname "$0")/src/claude_token_usage.1m.sh"
