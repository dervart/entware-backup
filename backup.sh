#!/bin/sh

# ============================================================
# Entware backup script
# ============================================================


# === ENVIRONMENT ===

# Cron runs scripts with a minimal PATH.
# Explicitly add Entware directories.
export PATH="/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin"


# === CONFIGURATION ===

WORK_DIR="/opt"

SMB_PATH="//1.2.3.4/obmen"
SMB_USER="backup-ent"
SMB_PASS="pass"
REMOTE_DIR="backup_entware"

# Number of backups to keep on the remote server.
KEEP_COUNT=7

LOG_FILE="/opt/backup.log"

# Number of compression threads used by pigz.
# This setting is ignored when pigz is not installed.
PIGZ_THREADS=2


# === INTERACTIVE MODE ===

# When stdout is connected to a terminal, show progress.
# When started by cron, keep the script non-interactive.
if [ -t 1 ]; then
    INTERACTIVE=1
else
    INTERACTIVE=0
fi


# === INITIALIZATION ===

# Recreate the log file on every run.
: > "$LOG_FILE"

BACKUP_NAME="entware_backup_$(date +%Y-%m-%d).tar.gz"
TMP_FILE="/tmp/$BACKUP_NAME"

EXCLUDE_FILE="/tmp/entware-backup-exclude"
FIFO_FILE="/tmp/entware-backup-pipe"


# === FUNCTIONS ===

log() {
    MESSAGE="$1"

    # Always write messages to the log file.
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $MESSAGE" >> "$LOG_FILE"

    # Also display messages when running interactively.
    if [ "$INTERACTIVE" -eq 1 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $MESSAGE"
    fi
}


error_exit() {
    log "ERROR: $1"
    exit 1
}


cleanup() {
    # Remove temporary files.
    rm -f "$EXCLUDE_FILE"
    rm -f "$FIFO_FILE"
}


# === CHECK REQUIRED COMMANDS ===

# Commands provided by BusyBox / the base system.
REQUIRED_COMMANDS="
date
rm
tar
grep
awk
wc
sort
head
du
mkfifo
smbclient
"

for cmd in $REQUIRED_COMMANDS; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error_exit "Required command not found: $cmd"
    fi
done


# gzip is required as the fallback compressor.
if ! command -v gzip >/dev/null 2>&1; then
    error_exit "Required command not found: gzip"
fi


# === OPTIONAL DEPENDENCIES ===

# pigz is optional.
# If installed, use multi-threaded compression.
# Otherwise, fall back to standard gzip.
if command -v pigz >/dev/null 2>&1; then
    COMPRESSOR="pigz"
    COMPRESSOR_ARGS="-p $PIGZ_THREADS"

    log "Compression: pigz ($PIGZ_THREADS threads)"
else
    COMPRESSOR="gzip"
    COMPRESSOR_ARGS=""

    log "Compression: gzip (pigz not installed)"
fi


# pv is optional.
# It is only used for interactive archive progress.
if [ "$INTERACTIVE" -eq 1 ]; then
    if command -v pv >/dev/null 2>&1; then
        PV_AVAILABLE=1
    else
        PV_AVAILABLE=0
        log "WARNING: pv is not installed."
        log "Archive progress will not be displayed."
    fi
else
    PV_AVAILABLE=0
fi


# === START ===

log "========================================"
log "Backup started"
log "Source: $WORK_DIR"
log "Destination: $SMB_PATH/$REMOTE_DIR"
log "Archive: $BACKUP_NAME"


# === 1. CLEAN OLD TEMPORARY BACKUPS ===

log "Cleaning up old temporary backup files..."

if ! rm -f /tmp/entware_backup_*.tar.gz; then
    log "WARNING: Failed to remove some old temporary backup files"
fi

# Remove possible leftovers from a previous interrupted run.
rm -f "$EXCLUDE_FILE"
rm -f "$FIFO_FILE"


# === 2. CHECK SOURCE DIRECTORY ===

if [ ! -d "$WORK_DIR" ]; then
    error_exit "Source directory does not exist: $WORK_DIR"
fi


# === 3. CREATE ARCHIVE ===

log "Creating archive..."


# Create the exclusion file.
# Do not include the current backup log in the archive.
printf '%s\n' "./backup.log" > "$EXCLUDE_FILE"


# Determine the approximate source size for pv.
SOURCE_SIZE_KB=$(du -sk "$WORK_DIR" 2>/dev/null | awk '{print $1}')

if [ -z "$SOURCE_SIZE_KB" ]; then
    cleanup
    error_exit "Unable to determine source directory size"
fi

SOURCE_SIZE=$((SOURCE_SIZE_KB * 1024))


# Create a named pipe.
#
# The FIFO allows tar and the compressor to run as separate
# processes. This makes it possible to check the exit status
# of both commands independently.
if ! mkfifo "$FIFO_FILE" 2>>"$LOG_FILE"; then
    cleanup
    error_exit "Failed to create temporary FIFO"
fi


# ------------------------------------------------------------
# Start tar in the background.
#
# tar writes an uncompressed archive stream into the FIFO.
# ------------------------------------------------------------

tar cf - \
    -X "$EXCLUDE_FILE" \
    -C "$WORK_DIR" . > "$FIFO_FILE" 2>>"$LOG_FILE" &

TAR_PID=$!


# ------------------------------------------------------------
# Start the compressor.
#
# Interactive mode with pv:
#
#   FIFO -> pv -> pigz/gzip -> archive
#
# Non-interactive mode:
#
#   FIFO -> pigz/gzip -> archive
# ------------------------------------------------------------

if [ "$INTERACTIVE" -eq 1 ] && [ "$PV_AVAILABLE" -eq 1 ]; then

    echo ""
    echo "Creating archive:"
    echo ""

    pv -s "$SOURCE_SIZE" -p -t -e -r -b < "$FIFO_FILE" | \
        $COMPRESSOR $COMPRESSOR_ARGS > "$TMP_FILE"

    COMPRESSOR_STATUS=$?

    echo ""

else

    $COMPRESSOR $COMPRESSOR_ARGS \
        < "$FIFO_FILE" \
        > "$TMP_FILE" \
        2>>"$LOG_FILE"

    COMPRESSOR_STATUS=$?

fi


# Wait for tar to finish and get its exit status.
wait "$TAR_PID"
TAR_STATUS=$?


# Remove temporary files.
cleanup


# === CHECK ARCHIVE CREATION STATUS ===

# Check tar first.
if [ "$TAR_STATUS" -ne 0 ]; then

    log "ERROR: tar failed with exit status $TAR_STATUS"
    log "Temporary archive preserved at: $TMP_FILE"

    exit 1
fi


# Check gzip/pigz.
if [ "$COMPRESSOR_STATUS" -ne 0 ]; then

    log "ERROR: $COMPRESSOR failed with exit status $COMPRESSOR_STATUS"
    log "Temporary archive preserved at: $TMP_FILE"

    exit 1
fi


# Check that the resulting archive actually exists.
if [ ! -s "$TMP_FILE" ]; then

    log "ERROR: Archive was not created or is empty"
    log "Temporary archive preserved at: $TMP_FILE"

    exit 1
fi


log "Archive created successfully"


# === 4. VERIFY ARCHIVE ===

log "Verifying archive..."

if ! tar tzf "$TMP_FILE" >/dev/null 2>&1; then

    log "ERROR: Archive verification failed"
    log "Temporary archive preserved at: $TMP_FILE"

    exit 1
fi

ARCHIVE_SIZE=$(du -h "$TMP_FILE" | awk '{print $1}')

log "Archive verified successfully (size: $ARCHIVE_SIZE)"


# === 5. CHECK / CREATE REMOTE DIRECTORY ===

log "Checking remote directory: $REMOTE_DIR"

if smbclient "$SMB_PATH" \
    -U "$SMB_USER%$SMB_PASS" \
    -c "cd $REMOTE_DIR" >/dev/null 2>&1; then

    log "Remote directory already exists"

else

    log "Remote directory does not exist. Creating..."

    MKDIR_OUTPUT=$(smbclient "$SMB_PATH" \
        -U "$SMB_USER%$SMB_PASS" \
        -c "mkdir $REMOTE_DIR" 2>&1)

    MKDIR_STATUS=$?

    if [ "$MKDIR_STATUS" -ne 0 ]; then

        # Another process may have created the directory
        # between the check and the mkdir command.
        if echo "$MKDIR_OUTPUT" | grep -q "NT_STATUS_OBJECT_NAME_COLLISION"; then

            log "Remote directory was created by another process"

        else

            log "ERROR: Failed to create remote directory"
            log "$MKDIR_OUTPUT"
            log "Temporary archive preserved at: $TMP_FILE"

            exit 1
        fi

    else

        log "Remote directory created successfully"

    fi
fi


# === 6. UPLOAD ARCHIVE ===

log "Uploading archive to SMB..."


if [ "$INTERACTIVE" -eq 1 ]; then

    echo ""
    echo "Uploading archive:"
    echo ""

    # smbclient displays its own transfer progress.
    # Display the output directly in the terminal and save it
    # to the log at the same time.
    smbclient "$SMB_PATH" \
        -U "$SMB_USER%$SMB_PASS" \
        -c "cd $REMOTE_DIR; put $TMP_FILE $BACKUP_NAME" \
        2>&1 | tee -a "$LOG_FILE"

    echo ""

else

    # Cron mode: keep smbclient output out of the terminal.
    UPLOAD_OUTPUT=$(smbclient "$SMB_PATH" \
        -U "$SMB_USER%$SMB_PASS" \
        -c "cd $REMOTE_DIR; put $TMP_FILE $BACKUP_NAME" 2>&1)

    UPLOAD_STATUS=$?

    if [ "$UPLOAD_STATUS" -ne 0 ]; then

        log "ERROR: Failed to upload archive"
        log "$UPLOAD_OUTPUT"
        log "Temporary archive preserved at: $TMP_FILE"

        exit 1
    fi

fi


# === 7. VERIFY UPLOADED FILE ===

log "Verifying uploaded archive..."

VERIFY_OUTPUT=$(smbclient "$SMB_PATH" \
    -U "$SMB_USER%$SMB_PASS" \
    -c "cd $REMOTE_DIR; ls $BACKUP_NAME" 2>&1)

VERIFY_STATUS=$?

if [ "$VERIFY_STATUS" -ne 0 ]; then

    log "ERROR: Uploaded archive could not be verified"
    log "$VERIFY_OUTPUT"
    log "Temporary archive preserved at: $TMP_FILE"

    exit 1
fi

log "Uploaded archive verified successfully"


# === 8. REMOVE LOCAL TEMPORARY ARCHIVE ===

if rm -f "$TMP_FILE"; then
    log "Temporary archive removed"
else
    log "WARNING: Failed to remove temporary archive: $TMP_FILE"
fi


# === 9. ROTATE OLD BACKUPS ===

log "Checking backup rotation..."

FILE_LIST=$(smbclient "$SMB_PATH" \
    -U "$SMB_USER%$SMB_PASS" \
    -c "cd $REMOTE_DIR; ls" 2>/dev/null | \
    grep -E '^  entware_backup_[0-9]{4}-[0-9]{2}-[0-9]{2}\.tar\.gz' | \
    awk '{print $1}')


if [ -n "$FILE_LIST" ]; then

    TOTAL=$(echo "$FILE_LIST" | wc -l)

    log "Found $TOTAL backup(s), keeping $KEEP_COUNT"

    if [ "$TOTAL" -gt "$KEEP_COUNT" ]; then

        DELETE_COUNT=$((TOTAL - KEEP_COUNT))

        log "Removing $DELETE_COUNT old backup(s)..."

        # Sort ascending, so the oldest backups are first.
        TO_DELETE=$(echo "$FILE_LIST" |
            sort |
            head -n "$DELETE_COUNT")

        for f in $TO_DELETE; do

            log "Deleting old backup: $f"

            if ! smbclient "$SMB_PATH" \
                -U "$SMB_USER%$SMB_PASS" \
                -c "cd $REMOTE_DIR; rm $f" >/dev/null 2>&1; then

                log "WARNING: Failed to delete old backup: $f"
            fi
        done

    else

        log "No rotation required"

    fi

else

    log "WARNING: Could not retrieve backup list"

fi


# === 10. FINISH ===

log "Backup completed successfully"
log "========================================"

exit 0
