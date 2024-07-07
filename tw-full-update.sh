#!/bin/bash
################################################################################
# I wanted a script to fully update my tumbleweed system and cleanup old files
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# v0.6 - Fixed some typos and comments. Also changed/fixed a couple minor things
# v0.5 - Changed colors to ansi and made the background the color. Still feel
#        like it can be better...
# v0.4 - Defined some min width/height values to display just the summary and
#        also the log if it's large enough. Added some logic to detect if a line
#        overflows and adjusts automatically.
# v0.3 - Added some color the summary block
# v0.2 - Now has a summary block using tput
# v0.1 - First version, just shell commands
################################################################################

# Minimum height/width for the window to display the summary
MIN_WIDTH=45
MIN_HEIGHT=11
# Set the minimum number of characters to display the log
LOG_MIN_CHARACTERS=300

# Get the current time
CURRENT_TIME=$(date +%Y-%m-%d_%H-%M-%S-%3N)

# Set the log file
LOG_FILE="/tmp/${CURRENT_TIME}_os-update.log"

# Drawing summary using variables was reset to the default value when it would refresh so lets use files.
STATUS_DIR="/tmp/${CURRENT_TIME}_update_status"
if [ ! -d "$STATUS_DIR" ]; then
  mkdir -p "$STATUS_DIR"
fi
echo " PENDING " > "$STATUS_DIR/refresh"
echo " PENDING " > "$STATUS_DIR/update"
echo " PENDING " > "$STATUS_DIR/dist_upgrade"
echo " PENDING " > "$STATUS_DIR/remove_deps"
echo " PENDING " > "$STATUS_DIR/update_flatpaks"
echo " PENDING " > "$STATUS_DIR/remove_flatpaks"

# Define some colors for the summary block
STATUS_RESET='\033[0m'         # Default background/text colors
STATUS_TEXT='\033[44;37m'      # Blue background, white text
STATUS_COMPLETED='\033[42;37m' # Green background, white text
STATUS_PENDING='\033[40;37m'   # Black background, white text
STATUS_RUNNING='\033[42;37m'   # Green background, white text
STATUS_SKIPPED=$STATUS_TEXT    # set as the regular summary text.
STATUS_FAILED='\033[41;37m'    # Red background, white text

# Read the status from file
read_status() {
  local key=$1
  cat "$STATUS_DIR/$key"
}

# Echo status with color
colored_status() {
  local status=$1
  case $status in
    "COMPLETED")
      echo -e "${STATUS_COMPLETED}${status}${STATUS_TEXT}"
      ;;
    " RUNNING ")
      echo -e "${STATUS_RUNNING}${status}${STATUS_TEXT}"
      ;;
    " PENDING ")
      echo -e "${STATUS_PENDING}${status}${STATUS_TEXT}"
      ;;
    " SKIPPED ")
      echo -e "${STATUS_SKIPPED}${status}${STATUS_TEXT}"
      ;;
    "  FAILED ")
      echo -e "${STATUS_FAILED}${status}${STATUS_TEXT}"
      ;;
    *)
      # Safety catch
      echo "$status"
      ;;
  esac
}

# Update status file
update_status() {
  local key=$1
  local value=$2
  echo "$value" > "$STATUS_DIR/$key"
}

# Get the number of lines in the terminal
get_terminal_height() {
  tput lines
}

# Get the number of columns in the terminal
get_terminal_width() {
  tput cols
}

wrap_log_lines() {
  local rows=$1
  local lines=$2
  local width=0
  width=$(get_terminal_width)

  local wrapped_lines=""
  wrapped_lines=$(fold -w "$width" <<< "$lines")
  tail -n "$rows" <<< "$wrapped_lines"
}

# Draw the summary
draw_summary() {
  local term_height
  local term_width
  term_height=$(get_terminal_height)
  term_width=$(get_terminal_width)

  if [ "$term_height" -ge "$MIN_HEIGHT" ] && [ "$term_width" -ge "$MIN_WIDTH" ]; then
    clear
    echo ""
    echo -e "${STATUS_TEXT}============================================"
    echo -e "${STATUS_TEXT}= Refreshing Repos...........[ $(colored_status "$(read_status refresh)") ] ="
    echo -e "${STATUS_TEXT}= Updating Packages..........[ $(colored_status "$(read_status update)") ] ="
    echo -e "${STATUS_TEXT}= Updating Distro............[ $(colored_status "$(read_status dist_upgrade)") ] ="
    echo -e "${STATUS_TEXT}= Removing old dependencies..[ $(colored_status "$(read_status remove_deps)") ] ="
    echo -e "${STATUS_TEXT}= Updating flatpaks..........[ $(colored_status "$(read_status update_flatpaks)") ] ="
    echo -e "${STATUS_TEXT}= Removing old flatpaks......[ $(colored_status "$(read_status remove_flatpaks)") ] ="
    echo -e "${STATUS_TEXT}============================================"
    echo -e "${STATUS_RESET}"

    # get available width and lines for logs
    local log_lines=$((term_height - 12))  # minus the summary height and few extra lines
    local log_characters=$(( term_width * log_lines)) # number of characters that can be displayed to shell
    if [ "$log_characters" -ge "$LOG_MIN_CHARACTERS" ]; then
      if [[ -f "$LOG_FILE" ]]; then
        wrap_log_lines $log_lines "$(tail -n "$log_lines" "$LOG_FILE")"
      else
        echo ""
      fi
    fi
  else
    clear
    echo "Error: The terminal must be at least ${MIN_WIDTH} columns wide and ${MIN_HEIGHT} lines high to display any output."
  fi
}

# Run a command, log to file, and update its status
run_command() {
  local command=$1
  local key=$2

  # Update status to running
  update_status "$key" " RUNNING "
  draw_summary

  # Run the command and log output
  eval "$command" >> "$LOG_FILE" 2>&1
  local result=$?

  # Update status to completed or failed
  if [ $result -eq 0 ]; then
    update_status "$key" "COMPLETED"
  else
    update_status "$key" "  FAILED "
    skip_remaining_tasks "$key"
    draw_summary
    cleanup_and_exit "$key"
  fi
  draw_summary
}

# Skip remaining tasks
skip_remaining_tasks() {
  local failed_task=$1
  local tasks=("refresh" "update" "dist_upgrade" "remove_deps" "update_flatpaks" "remove_flatpaks")
  local start_skipping=false

  for task in "${tasks[@]}"; do
    if [[ $task == "$failed_task" ]]; then
      start_skipping=true
      continue
    fi

    if $start_skipping; then
      update_status "$task" " SKIPPED "
    fi
  done
}

# Periodically redraw the summary
update_summary_periodically() {
  while : ; do
    sleep 1
    draw_summary
  done
}

# Display the programs that should be restarted and the RPM config check
display_post_update_info() {
  # Get the output for processes using deleted files
  local output=""
  output=$(zypper ps -s)

  # Check if the output contains "No processes using deleted files"
  echo -e "\n\n"
  if [[ $output != *"No processes using deleted files"* ]]; then
    # There's stuff using deleted files, list them
    echo "#####################################"
    echo "# Programs that should be restarted #"
    echo "#####################################"
    echo "$output"
  else
    echo -e "No programs using deleted files so reboot is probably not necessary."
  fi

  # Check if there's any rpm configs that need updating
  output=$(rpmconfigcheck)

  # Check if the output is not empty
  echo -e "\n\n"
  if [[ -n $output ]]; then
    if [ "$output" != "Searching for unresolved configuration files" ]; then
      # there's files, display them
      echo "####################"
      echo "# rpm config check #"
      echo "####################"
      echo "$output"
    else
      echo "No rpm configs that need updates."
    fi
  else
    echo "No rpm configs that need updates."
  fi
}

# Clean up and exit on failure
cleanup_and_exit() {
  local failed_task=$1
  kill $SUMMARY_PID
#  rm -r "$STATUS_DIR"

  if [[ $failed_task != "refresh" ]]; then
    display_post_update_info
  fi

  echo -e "\n\n"
  echo "If you want to view the log or keep it, please move it from /tmp"
  echo "Log: ${LOG_FILE}"

  exit 1
}

# Periodic summary updates in the background
update_summary_periodically &

# Background process ID to kill it later
SUMMARY_PID=$!

# Running the commands
run_command "zypper -n refresh" "refresh"
run_command "zypper -n update" "update"
run_command "zypper -n dist-upgrade" "dist_upgrade"

# Check if there are packages to be removed
if [ "$(zypper packages --unneeded | awk -F'|' 'NR<=4 {next} {print $3}' | grep -v Name | grep -c .)" -ne 0 ]; then
  run_command "zypper packages --unneeded | awk -F'|' 'NR==0 || NR==1 || NR==2 || NR==3 || NR==4 {next} {print \$3}' | grep -v Name | xargs zypper -n remove --clean-deps" "remove_deps"
else
  update_status "remove_deps" "COMPLETED"
  draw_summary
fi

# Deal with flatpaks
run_command "flatpak update --system -y" "update_flatpaks"
run_command "flatpak uninstall --unused --system -y" "remove_flatpaks"

# Kill the background process for periodic updates
kill $SUMMARY_PID

# Final draw to show the completed status summary
draw_summary

# Cleanup the directory/files used to store status
rm -r "$STATUS_DIR"

# Display the programs that should be restarted and the RPM config check
display_post_update_info

# Display details about the log file used/left
echo -e "\n\n"
echo "Note: If you want to view the log"
echo "Log: ${LOG_FILE}"
echo "If you want to keep it, make sure you move it from /tmp before a reboot."
