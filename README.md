# syno-wg-autoinstaller.sh
This script will build the latest version of WireGuard for your Synology NAS and install/update the package. It must be used on a Synology DiskStation NAS so that it can detect your DSM version, package architecture, and interact with your NAS. The script will ask for `sudo` access - Depending on how long it takes to build the WireGuard SPK, you may have to enter your password for `sudo` twice.

## Setup
1. [Enable SSH](https://www.synology.com/en-global/knowledgebase/DSM/tutorial/General_Setup/How_to_login_to_DSM_with_root_permission_via_SSH_Telnet) if not already enabled
2. Check that the Synology official Docker and Git Server packages are installed
3. Check that the Trust Level is set to "Any publisher" in the Package Center settings
4. SSH into your NAS with a user with root access
5. Run `wget https://raw.githubusercontent.com/raman325/syno-wg-autoinstaller/master/syno-wg-autoinstaller.sh`
6. Run `chmod +x syno-wg-autoinstaller.sh`

## Usage
For basic usage, simply run `./syno-wg-autoinstaller.sh`. For advanced usage, run `./syno-wg-autoinstaller.sh --help` to see configuration options.

NOTE: Until the parent repo (https://github.com/runfalk/synology-wireguard.git) accepts my PR, you will have to pass the following flags to `./syno-wg-autoinstaller.sh`: `-u https://github.com/raman325/synology-wireguard.git` and `-b latest_version_on_run`. The full run statement would be `./syno-wg-autoinstaller.sh -u https://github.com/raman325/synology-wireguard.git -b latest_version_on_run`
