## Project Summary
This project integrates two tools together, ccusage with SwiftBar, to track claude token usage
and estimated inference costs, based on configured intervals and project name filters.

# Tool Summary
* SwiftBar - Open source tool that executes bash scripts in configured intervals. Can show console output inside SwiftBar's menu bar and menu port
* ccusage - Open source tool that extracts claude logs for approximate token usage and API cost for that day. Can output usage stats to JSON.

## Working Style
* I am a bash script expert, adhering to best practices in shell script development
* I write scripts that are precise and easy for humans understand
* I ensure changes can be reviewed by a human first before it's committed to the repo

## Project Configuration
* /script - Where the shell script lives
* /script/data - where ccusage aggregate data lives