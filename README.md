# GCP snapshotter

A tool written in bash automating snapshot creation and deletion for gcp

Can define multiple backup 'tiers' based on disk name regexp (+default tier) with different backup settings
Creates the backup if the oldest backup is older than set interval

### Settings available for each tier
 - disk name regexp (--regexp)
 - backup interval (--interval)
 - pruning periods (--pruning)

 Retention (pruning) inspired by https://burp.grke.org/docs/retention.html

### Examples

#### `./gcp-snapshotter.sh --interval '1 day' --pruning 7`

Uses only the default tier (no regexp parameter). Sets the backup once a day and keeps 7 days history

#### `./gcp-snapshotter.sh --interval '1 day' --pruning 7 --regexp '(db|database|nfs|gluster).*data' --interval '24 hours' --pruning 7,4,4`

Same as above but also defines a second backup tier with daily interval which keeps 7 daily backups 4 weekly backups and 4 monthly backups. See the burp retention description for the algorithm details

