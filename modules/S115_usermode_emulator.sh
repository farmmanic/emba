#!/bin/bash

# emba - EMBEDDED LINUX ANALYZER
#
# Copyright 2020 Siemens Energy AG
#
# emba comes with ABSOLUTELY NO WARRANTY. This is free software, and you are
# welcome to redistribute it under the terms of the GNU General Public License.
# See LICENSE file for usage of this software.
#
# emba is licensed under GPLv3
#
# Author(s): Michael Messner, Pascal Eckmann

# Description:  Module with all available functions and patterns to use
#               Access:
#                 firmware root path via $FIRMWARE_PATH
#                 binary array via ${BINARIES[@]}

S115_usermode_emulator() {
  module_log_init "${FUNCNAME[0]}"
  if [[ "$QEMULATION" -eq 1 ]]; then
    module_title "Software component and version detection started via emulation with qemu usermode emulation"

    print_output "[!] This module is experimental and could harm your host environment."
    print_output "[!] This module creates a working copy of the firmware filesystem in the log directory $LOG_DIR.\\n"

    print_output "[*] Should we proceed?\\n"
#    read -p "(y/N)  " -r ANSWER
#    case ${ANSWER:0:1} in
#      n|N|"" )
#        echo
#        print_output "[!] Terminating emba now.\\n"
#        exit 1
#      ;;
#    esac

    SHORT_PATH_BAK=$SHORT_PATH
    SHORT_PATH=1
    declare -a MISSING

    # as we modify the firmware we copy it to the log directory and do stuff in this area
    copy_firmware

    for LINE in "${BINARIES[@]}" ; do
      if ( file "$LINE" | grep -q ELF ) && [[ "$LINE" != './qemu-'*'-static' ]]; then
        if ( file "$LINE" | grep -q "x86-64" ) ; then
          EMULATOR="qemu-x86_64-static"
        elif ( file "$LINE" | grep -q "Intel 80386" ) ; then
          EMULATOR="qemu-i386-static"
        elif ( file "$LINE" | grep -q "32-bit LSB.*ARM" ) ; then
          EMULATOR="qemu-arm-static"
        elif ( file "$LINE" | grep -q "32-bit MSB.*ARM" ) ; then
          EMULATOR="qemu-armeb-static"
        elif ( file "$LINE" | grep -q "32-bit LSB.*MIPS" ) ; then
          EMULATOR="qemu-mipsel-static"
        elif ( file "$LINE" | grep -q "32-bit MSB.*MIPS" ) ; then
          EMULATOR="qemu-mips-static"
        elif ( file "$LINE" | grep -q "32-bit MSB.*PowerPC" ) ; then
          EMULATOR="qemu-ppc-static"
        else
          print_output "[-] No working emulator found for ""$LINE"
          EMULATOR="NA"
        fi

        if [[ "$EMULATOR" != "NA" ]]; then
          detect_root_dir
          prepare_emulator
          emulate_binary
        fi
        running_jobs
      fi
    done

    cleanup
    running_jobs
    filesystem_fixes
    version_detection

  else
    echo
    print_output "[!] Automated emulation is disabled."
    print_output "$(indent "Enable it with the parameter -E.")"
  fi
}

filesystem_fixes() {
  if [[ "${#MISSING[@]}" -ne 0 ]]; then
    sub_module_title "Filesystem fixes"
    print_output "[*] Emba has auto-generated the files during runtime."
    print_output "[*] For persistence you could generate it manually in your filesystem.\\n"
    for MISSING_FILE in "${MISSING[@]}"; do
      print_output "[*] Missing file: $MISSING_FILE"
    done
  fi
}

version_detection() {
  sub_module_title "Software component and version detection started"

  while read -r VERSION_LINE; do 
    BINARY="$(echo "$VERSION_LINE" | cut -d: -f1)"
    STRICT="$(echo "$VERSION_LINE" | cut -d: -f2)"
    VERSION_IDENTIFIER="$(echo "$VERSION_LINE" | cut -d: -f3- | sed s/^\"// | sed s/\"$//)"

    # if we have the key strict this version identifier only works for the defined binary and is not generic!
    if [[ $STRICT == "strict" ]]; then
      VERSION_STRICT=$(grep -o -e "$VERSION_IDENTIFIER" "$LOG_DIR"/qemu_emulator/qemu_"$BINARY"* | sort -u | head 1 2>/dev/null)
      if [[ "$BINARY" == "smbd" ]]; then
        BINARY="samba"
      fi
      VERSION_STRICT="$BINARY $VERSION_STRICT"
      VERSIONS_DETECTED+=( "$VERSION_STRICT" )
    else
      readarray -t VERSIONS_DETECTED < <(grep -o -e "$VERSION_IDENTIFIER" "$LOG_DIR"/qemu_emulator/*)
    fi

    if [[ ${#VERSIONS_DETECTED[@]} -ne 0 ]]; then
      for VERSION_DETECTED in "${VERSIONS_DETECTED[@]}"; do
        # if we have multiple detection of the same version details:
        if [ "$VERSION_DETECTED" != "$VERS_DET_OLD" ]; then
          VERS_DET_OLD="$VERSION_DETECTED"
          VERSIONS_BIN="$(basename "$(echo "$VERSION_DETECTED" | cut -d: -f1)")"
          VERSION_DETECTED="$(echo "$VERSION_DETECTED" | cut -d: -f2-)"
          print_output "[+] Version information found ${RED}""$VERSION_DETECTED""${NC}${GREEN} (from binary $BINARY) found in $VERSIONS_BIN."
        fi
      done
    fi
  done < "$CONFIG_DIR"/bin_version_strings.cfg 
  echo
}

detect_root_dir() {
  INTERPRETER_FULL_PATH=$(find "$EMULATION_PATH_BASE" -ignore_readdir_race -type f -executable -exec file {} \; 2>/dev/null | grep "ELF" | grep "interpreter" | sed s/.*interpreter\ // | sed s/,\ .*$// | sort -u 2>/dev/null)
  if [[ $(echo "$INTERPRETER_FULL_PATH" | wc -l) -gt 0 ]]; then
    # now we have a result like this "/lib/ld-uClibc.so.0"
    INTERPRETER=$(echo "$INTERPRETER_FULL_PATH" | sed -e 's/\//\\\//g')
    EMULATION_PATH=$(find "$EMULATION_PATH_BASE" -ignore_readdir_race -wholename "*$INTERPRETER_FULL_PATH" 2>/dev/null | sort -u)
    EMULATION_PATH="${EMULATION_PATH//$INTERPRETER/}"
  else
    # if we can't find the interpreter we fall back to the original root directory
    EMULATION_PATH=$EMULATION_PATH_BASE
  fi
  # if the new root directory does not include the current working directory we fall back to the original root directory
  if [[ ! "$EMULATION_PATH" == *"$EMULATION_PATH_BASE"* ]]; then
    EMULATION_PATH=$(find "$EMULATION_PATH_BASE" -path "*root/bin" -exec dirname {} \;)
    #EMULATION_PATH=$EMULATION_PATH_BASE
  fi
  print_output "[*] Using the following path as emulation root path: $EMULATION_PATH"
}

copy_firmware() {
  print_output "[*] Create a firmware backup for emulation ..."
  cp -pri "$FIRMWARE_PATH" "$LOG_DIR"/ 2> /dev/null
  EMULATION_DIR=$(basename "$FIRMWARE_PATH")
  EMULATION_PATH_BASE="$LOG_DIR"/"$EMULATION_DIR"
}

running_jobs() {
  CJOBS=$(pgrep -a "$EMULATOR")
  if [[ -n "$CJOBS" ]] ; then
    echo
    print_output "[*] Currently running emulation jobs: $(echo "$CJOBS" | wc -l)"
    print_output "$(indent "$CJOBS")""\\n"
  else
    CJOBS="NA"
  fi
}

cleanup() {
  # reset the terminal after all the uncontrolled emulation it is typically broken!
  reset

  print_output "[*] Terminating qemu processes - check it with ps"
  mapfile -t CJOBS < <(pgrep -f "$EMULATOR")
  for PID in "${CJOBS[@]}"; do
    print_output "[*] Terminating process ""$PID"
    kill "$PID" 2> /dev/null
  done

  CJOBS_=$(pgrep qemu-)
  if [[ -n "$CJOBS_" ]] ; then
    print_output "[*] More emulation jobs are running ... we kill it with fire\\n"
    killall -9 "$EMULATOR" 2> /dev/null
  fi

  EMULATORS_=( qemu*static )
  if (( ${#EMULATORS_[@]} )) ; then
    print_output "[*] Cleaning the emulation environment\\n"
    rm "$EMULATION_PATH"/qemu*static 2> /dev/null
  fi

  echo
  print_output "[*] Umounting proc, sys and run"
  umount -l "$EMULATION_PATH""/proc"
  umount "$EMULATION_PATH""/sys"
  umount "$EMULATION_PATH""/run"

  FILES=$(find "$LOG_DIR""/qemu_emulator/" -type f -name "qemu_*" 2>/dev/null)
  if [[ -n "$FILES" ]] ; then
    print_output "[*] Cleanup empty log files.\\n\\n"
    for FILE in $FILES ; do
      if [[ ! -s "$FILE" ]] ; then
        rm "$FILE" 2> /dev/null
      else
        BIN=$(basename "$FILE")
        BIN=$(echo "$BIN" | cut -d_ -f2 | sed 's/.txt$//')
        print_output "[+]""${NC}"" Emulated binary ""${GREEN}""$BIN""${NC}"" generated output in ""${GREEN}""$FILE""${NC}"". Please check this manually."
      fi
    done
  fi
  SHORT_PATH=$SHORT_PATH_BAK
}

prepare_emulator() {

  if [[ ! -f "$EMULATION_PATH""/""$EMULATOR" ]]; then
    print_output "[*] Preparing the environment for usermode emulation"
    if ! command -v "$EMULATOR" > /dev/null ; then
      echo
      print_output "[!] Is the qemu package installed?"
      print_output "$(indent "We can't find it!")"
      print_output "$(indent "$(red "Terminating emba now.\\n")")"
      exit 1
    fi
    cp "$(which $EMULATOR)" "$EMULATION_PATH"/

    if ! [[ -d "$EMULATION_PATH""/proc" ]] ; then
      mkdir "$EMULATION_PATH""/proc" 2> /dev/null
    fi

    if ! [[ -d "$EMULATION_PATH""/sys" ]] ; then
      mkdir "$EMULATION_PATH""/sys" 2> /dev/null
    fi

    if ! [[ -d "$EMULATION_PATH""/run" ]] ; then
      mkdir "$EMULATION_PATH""/run" 2> /dev/null
    fi

    if ! [[ -d "$EMULATION_PATH""/dev/" ]] ; then
      mkdir "$EMULATION_PATH""/dev/" 2> /dev/null
    fi

    mount proc "$EMULATION_PATH""/proc" -t proc 2> /dev/null
    mount -o bind /run "$EMULATION_PATH""/run" 2> /dev/null
    mount -o bind /sys "$EMULATION_PATH""/sys" 2> /dev/null

    if [[ -e "$EMULATION_PATH""/dev/console" ]] ; then
      rm "$EMULATION_PATH""/dev/console" 2> /dev/null
    fi
    mknod -m 622 "$EMULATION_PATH""/dev/console" c 5 1 2> /dev/null

    if [[ -e "$EMULATION_PATH""/dev/null" ]] ; then
      rm "$EMULATION_PATH""/dev/null" 2> /dev/null
    fi
    mknod -m 666 "$EMULATION_PATH""/dev/null" c 1 3 2> /dev/null

    if [[ -e "$EMULATION_PATH""/dev/zero" ]] ; then
      rm "$EMULATION_PATH""/dev/zero" 2> /dev/null
    fi
    mknod -m 666 "$EMULATION_PATH""/dev/zero" c 1 5 2> /dev/null

    if [[ -e "$EMULATION_PATH""/dev/ptmx" ]] ; then
      rm "$EMULATION_PATH""/dev/ptmx" 2> /dev/null
    fi
    mknod -m 666 "$EMULATION_PATH""/dev/ptmx" c 5 2 2> /dev/null

    if [[ -e "$EMULATION_PATH""/dev/tty" ]] ; then
      rm "$EMULATION_PATH""/dev/tty" 2> /dev/null
    fi
    mknod -m 666 "$EMULATION_PATH""/dev/tty" c 5 0 2> /dev/null

    if [[ -e "$EMULATION_PATH""/dev/random" ]] ; then
      rm "$EMULATION_PATH""/dev/random" 2> /dev/null
    fi
    mknod -m 444 "$EMULATION_PATH""/dev/random" c 1 8 2> /dev/null

    if [[ -e "$EMULATION_PATH""/dev/urandom" ]] ; then
      rm "$EMULATION_PATH""/dev/urandom" 2> /dev/null
    fi
    mknod -m 444 "$EMULATION_PATH""/dev/urandom" c 1 9 2> /dev/null

    chown -v root:tty "$EMULATION_PATH""/dev/"{console,ptmx,tty} > /dev/null 2>&1

    print_output ""
    print_output "[*] Currently mounted areas:"
    print_output "$(indent "$(mount | grep "$EMULATION_PATH" 2> /dev/null )")""\\n"

  fi
  if ! [[ -d "$LOG_DIR""/qemu_emulator" ]] ; then
    mkdir "$LOG_DIR""/qemu_emulator" 2> /dev/null
  fi
}

emulate_strace_run() {
    echo
    print_output "[*] Initial strace run on command ${GREEN}$BIN_EMU_NAME${NC} for identifying missing areas"

    # currently we only look for file errors (errno=2) and try to fix this
    chroot "$EMULATION_PATH" ./"$EMULATOR" --strace "$BIN_EMU" > "$LOG_DIR""/qemu_emulator/stracer_""$BIN_EMU_NAME"".txt" 2>&1 &
    PID=$!

    # wait a second and then kill it
    sleep 1
    kill -0 -9 "$PID" 2> /dev/null

    mapfile -t MISSING_AREAS < <(grep -a "open" "$LOG_DIR""/qemu_emulator/stracer_""$BIN_EMU_NAME"".txt" | grep -a "errno=2\ " 2>&1 | cut -d\" -f2 2>&1 | sort -u)

    for MISSING_AREA in "${MISSING_AREAS[@]}"; do
      MISSING+=("$MISSING_AREA")
      if [[ "$MISSING_AREA" != */proc/* || "$MISSING_AREA" != */sys/* ]]; then
        print_output "[*] Found missing area: $MISSING_AREA"
  
        FILENAME_MISSING=$(basename "$MISSING_AREA")
        print_output "[*] Trying to create this missing file: $FILENAME_MISSING"
        PATH_MISSING=$(dirname "$MISSING_AREA")
        if [[ ! -d "$EMULATION_PATH""$PATH_MISSING" ]]; then
          if [[ -L "$EMULATION_PATH""$PATH_MISSING" ]]; then
            if [[ -e "$EMULATION_PATH""$PATH_MISSING" ]]; then
              print_output "[*] Good symlink: $PATH_MISSING"
            else
              print_output "[-] Broken symlink: $PATH_MISSING"
            fi
          elif [[ -e "$EMULATION_PATH""$PATH_MISSING" ]]; then
            print_output "[-] Not a symlink: $PATH_MISSING"
          else
            print_output "[*] Missing path: $PATH_MISSING"
          fi
        fi

        FILENAME_FOUND=$(find "$EMULATION_PATH" -ignore_readdir_race -path "$EMULATION_PATH"/sys -prune -false -o -path "$EMULATION_PATH"/proc -prune -false -o -type f -name "$FILENAME_MISSING")
        if [[ -n "$FILENAME_FOUND" ]]; then
          print_output "[*] Possible matching file found: $FILENAME_FOUND"
        fi
    
        if [[ ! -d "$EMULATION_PATH""$PATH_MISSING" ]]; then
          print_output "[*] Creating directory $EMULATION_PATH$PATH_MISSING"
          mkdir -p "$EMULATION_PATH""$PATH_MISSING" 2> /dev/null
        fi
        if [[ -n "$FILENAME_FOUND" ]]; then
          print_output "[*] Copy file $FILENAME_FOUND to $EMULATION_PATH$PATH_MISSING/"
          cp "$FILENAME_FOUND" "$EMULATION_PATH""$PATH_MISSING"/ 2> /dev/null
        else
          print_output "[*] Creating empty file $EMULATION_PATH$PATH_MISSING/$FILENAME_MISSING"
          touch "$EMULATION_PATH""$PATH_MISSING"/"$FILENAME_MISSING" 2> /dev/null
        fi
      fi
    done
    rm "$LOG_DIR""/qemu_emulator/stracer_""$BIN_EMU_NAME"".txt"
}

emulate_binary() {
  BIN_EMU_NAME="$(basename "$LINE")"

  ## as we currently do not have the right path of our binary we have to find it now:
  DIR=$(pwd)
  BIN_EMU="$(cd "$EMULATION_PATH" && find . -ignore_readdir_race -type f -executable -name "$BIN_EMU_NAME" 2>/dev/null && cd "$DIR" || exit)"

  emulate_strace_run
  
  # emulate binary with different command line parameters:
  EMULATION_PARAMS=("" "-v" "-V" "-h" "-help" "--help" "--version" "version")
  echo
  for PARAM in "${EMULATION_PARAMS[@]}"; do
    print_output "[*] Trying to emulate binary ${GREEN}""$BIN_EMU""${NC} with parameter ""$PARAM"""

    chroot "$EMULATION_PATH" ./"$EMULATOR" "$BIN_EMU" "$PARAM" | tee -a "$LOG_DIR""/qemu_emulator/qemu_""$BIN_EMU_NAME"".txt" 2>&1 &
    print_output ""
  done
  # reset the terminal after all the uncontrolled emulation it is typically broken!
  reset
}

