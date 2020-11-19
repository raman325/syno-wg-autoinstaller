#!/bin/bash

# TODO: figure out how to intercept calls to https://sourceforge.net/projects/dsgpl/files/toolkit/DSM6.2/ so I can cache files for iteration purposes.
# TODO: If DSM_VER or PACKAGE_ARCH change, delete old artifacts
# TODO: Figure out how to persist container. Currently fails on second run (mounting /proc returns "permission denied")

INSTALL_WG=1
KEEP_BUILD_ARTIFACTS=1
GIT_URL="https://github.com/runfalk/synology-wireguard.git"
GIT_BRANCH="master"

usage() {
    echo "Usage: syno-wg-autoinstaller.sh [OPTIONS]"
    echo ''
    echo 'Options:'
    echo '  -ni | --no-install              Stops script from installing/'
    echo '                                  upgrading WireGuard after building'
    echo '                                  package.'
    echo '  -d  | --delete-build-artifacts  Deletes all build artifacts at the'
    echo '                                  end of the script. Saves space but'
    echo '                                  increases overall time to run.'
    echo '  -s | --keep-spk                 Retains the WireGuard SPK file that'
    echo '                                  is built by this script.'
    echo '  -p | --git-path                 Sets the path for the repo containing'
    echo '                                  Dockerfile to build WireGuard package.'
    echo '                                  Defaults to repo name.'
    echo '  -u  | --git-url                 URL to Git repo containing Dockerfile'
    echo '                                  to build the WireGuard package.'
    echo '                                  Defaults to '
    echo '                           "https://github.com/runfalk/synology-wireguard.git".'
    echo '  -b  | --git-branch              Branch of git repo to use.'
    echo '                                  Defaults to `master`'
    echo '  -h  | --help                    Access this help menu.'
}

while [ "$1" != "" ]; do
    case $1 in
    -ni | --no-install)
        unset INSTALL_WG
        shift
        ;;
    -d | --delete-build-artifacts)
        unset KEEP_BUILD_ARTIFACTS
        shift
        ;;
    -s | --keep-spk)
        KEEP_WG_SPK=1
        shift
        ;;
    -p | --git-path)
        shift
        GIT_PATH=$1
        shift
        ;;
    -u | --git-url)
        shift
        GIT_URL=$1
        shift
        ;;
    -b | --git-branch)
        shift
        GIT_BRANCH=$1
        shift
        ;;
    -h | --help)
        usage
        exit
        ;;
    *)
        usage
        exit 1
        ;;
    esac
done

startWireGuardInterface() {
    echo "Starting interface $1"
    sudo wg-quick up $1
}

SYNO_CONF="/etc.defaults/synoinfo.conf"
SYNO_VERSION=/etc.defaults/VERSION

if [[ ! -f $SYNO_CONF ]] || [[ $(cat $SYNO_CONF | grep "upnpmodelname=\"DS" | wc -l) -eq "0" ]]; then
    echo "This script must be run from a Synology Diskstation."
    echo
    exit
fi

WG_BUILDER_NAME=synobuild
BASE_BUILD_PATH="build_artifacts"

BASE_WIREGUARD_URL="https://git.zx2c4.com"
WIREGUARD_REPO_NAME="wireguard-linux-compat"
WIREGUARD_TOOLS_REPO_NAME="wireguard-tools"
LIBMNL_URL="https://netfilter.org/projects/libmnl/files/?C=M;O=D"

WIREGUARD_VERSION=$(wget -q $BASE_WIREGUARD_URL/$WIREGUARD_REPO_NAME/refs/ -O - | grep -oP "\/$WIREGUARD_REPO_NAME\/tag\/\?h=v\K[.0-9]*" | head -n 1)
WIREGUARD_TOOLS_VERSION=$(wget -q $BASE_WIREGUARD_URL/$WIREGUARD_TOOLS_REPO_NAME/refs/ -O - | grep -oP "\/$WIREGUARD_TOOLS_REPO_NAME\/tag\/\?h=v\K[.0-9]*" | head -n 1)
LIBMNL_VERSION=$(wget -q $LIBMNL_URL -O - | grep -oP 'a href="libmnl-\K[0-9.]*' | head -n 1 | sed "s/.\{1\}$//")
CURR_DSM_MAJOR=$(cat $SYNO_VERSION | head -n 1 | cut -d'"' -f 2)
CURR_DSM_MINOR=$(cat $SYNO_VERSION | head -n 2 | tail -n 1 | cut -d'"' -f 2)
CURR_DSM_VER="$CURR_DSM_MAJOR.$CURR_DSM_MINOR"
CURR_PACKAGE_ARCH=$(cat $SYNO_CONF | grep synobios | cut -d'"' -f 2)
INSTALLED_WIREGUARD_PACKAGE_NAME=$(sudo synopkg list | grep WireGuard | grep -oP "[a-zA-Z0-9.-]*" | head -n 1)
INSTALLED_WIREGUARD_VERSION=$(echo $INSTALLED_WIREGUARD_PACKAGE_NAME | grep -oP "[0-9]+[0-9.-]*")

# If there is an existing container, check if it was built with expected PACKAGE_ARCH and DSM_VER. If not, schedule deletion.
if [[ $(sudo docker ps -a | grep $WG_BUILDER_NAME | wc -l) -gt "0" ]]; then
    EXISTING_SYNO_BUILD_CONTAINER=1
    PREV_DSM_VER=$(sudo docker container inspect $WG_BUILDER_NAME | grep DSM_VER | head -n 1 | grep -oP "[0-9.]*")
    PREV_PACKAGE_ARCH=$(sudo docker container inspect $WG_BUILDER_NAME | grep PACKAGE_ARCH | head -n 1 | grep -oP "=\K[a-zA-z0-9]+")
    if [[ $CURR_DSM_VER -ne "$PREV_DSM_VER" ]] || [[ $CURR_PACKAGE_ARCH -ne $PREV_PACKAGE_ARCH ]]; then
        DEL_OLD_SYNO_BUILD_CONTAINER=1
    fi
fi

echo "DSM version: $CURR_DSM_VER"
echo "Package Architecture: $CURR_PACKAGE_ARCH"
echo "WireGuard latest version: $WIREGUARD_VERSION"
if [[ ! -z $INSTALLED_WIREGUARD_VERSION ]]; then
    echo "WireGuard installed version: $INSTALLED_WIREGUARD_VERSION"
else
    echo "WireGuard installed version: N/A"
fi
echo "WireGuard Tools latest version: $WIREGUARD_TOOLS_VERSION"
echo "libnml latest version: $LIBMNL_VERSION"
echo

if [[ ! -z $INSTALLED_WIREGUARD_VERSION ]] && [[ $WIREGUARD_VERSION == $INSTALLED_WIREGUARD_VERSION ]]; then
    echo "You are already running the latest version of WireGuard"
    echo
    exit
fi

# Set up git repo for Docker image
mkdir -p $BASE_BUILD_PATH

if [[ -z $GIT_PATH ]]; then
    GIT_PATH=$(basename $GIT_URL .git | awk '{print tolower($0)}')
fi

if [[ ! -d "$BASE_BUILD_PATH/$GIT_PATH" ]]; then
    echo "Cloning Git repo"
    git clone $GIT_URL "$BASE_BUILD_PATH/$GIT_PATH"
else
    cd $BASE_BUILD_PATH/$GIT_PATH
    GIT_CURRENT_URL=$(git config --get remote.origin.url)

    if [[ -z $GIT_CURRENT_URL ]]; then
        cd ../..
        echo "$BASE_BUILD_PATH/$GIT_PATH is an existing folder that is not a Git repo. Choose a different path or rename/delete the existing folder then rerun the script."
        echo
        exit
    elif [[ $GIT_CURRENT_URL == $GIT_URL ]]; then
        GIT_CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
        if [[ $GIT_CURRENT_BRANCH != $GIT_BRANCH ]]; then
            SWITCH_BRANCH=1
            echo "Existing Git repo found but on the wrong branch."
            IS_DIRTY=$(git status -s | grep "^A ")
            if [[ ! -z IS_DIRTY ]]; then
                echo "Working directory is dirty. Stashing changes for later."
                git stash
            fi
            git checkout $GIT_BRANCH
        else
            echo "Existing Git repo found on correct branch"
        fi
        echo "Pulling latest changes"
        git pull origin $GIT_BRANCH
    else
        cd ../..
        echo "Existing Git repo found but origin URL doesn't match. Choose a different path or rename/delete the existing folder then rerun the script."
        echo "Folder exists at $BASE_BUILD_PATH/$GIT_PATH"
        exit
    fi
    cd ../..
fi

echo

mkdir -p $BASE_BUILD_PATH
mkdir -p $BASE_BUILD_PATH/toolkit_tarballs

echo "Building Docker image"
sudo docker build -t $WG_BUILDER_NAME "$BASE_BUILD_PATH/$GIT_PATH"
echo "Done building Docker image"
echo

# Delete old build container
if [[ $DEL_OLD_SYNO_BUILD_CONTAINER -eq "1" ]]; then
    echo "Found old $WG_BUILDER_NAME Docker container that needs to be updating. Deleting old container"
    sudo docker container rm -f $WG_BUILDER_NAME
    echo "Container deleted"
    echo
fi

# Create new build container. If build fails because memneq work-around isn't needed, retry with correct environment variables
if [[ -z $EXISTING_SYNO_BUILD_CONTAINER ]]; then
    echo "Creating and running Docker container"
    sudo docker run \
        --rm \
        --name $WG_BUILDER_NAME \
        --privileged \
        --security-opt=apparmor:unconfined \
        --env PACKAGE_ARCH=$CURR_PACKAGE_ARCH --env DSM_VER="$CURR_DSM_VER" \
        --env WIREGUARD_VERSION="$WIREGUARD_VERSION" \
        --env WIREGUARD_TOOLS_VERSION="$WIREGUARD_TOOLS_VERSION" \
        --env LIBMNL_VERSION="$LIBMNL_VERSION" \
        -v $(pwd)/$BASE_BUILD_PATH:/result_spk \
        -v $(pwd)/$BASE_BUILD_PATH/toolkit_tarballs:/toolkit_tarballs \
        $WG_BUILDER_NAME 2>&1 | tee tmp.log
    if [[ $(cat tmp.log | grep "error: redefinition of 'crypto_memneq'" | wc -l) -gt "0" ]]; then
        echo "Architecture does not need memneq workaround. Rerunning container without it."
        sudo docker run \
            --rm \
            --name $WG_BUILDER_NAME \
            --privileged \
            --security-opt=apparmor:unconfined \
            --env HAS_MEMNEQ=1 \
            --env PACKAGE_ARCH=$CURR_PACKAGE_ARCH --env DSM_VER="$CURR_DSM_VER" \
            --env WIREGUARD_VERSION="$WIREGUARD_VERSION" \
            --env WIREGUARD_TOOLS_VERSION="$WIREGUARD_TOOLS_VERSION" \
            --env LIBMNL_VERSION="$LIBMNL_VERSION" \
            -v $(pwd)/$BASE_BUILD_PATH:/result_spk \
            -v $(pwd)/$BASE_BUILD_PATH/toolkit_tarballs:/toolkit_tarballs \
            $WG_BUILDER_NAME | tee tmp.log ||
            {
                echo "Docker run failed, check tmp.log for details"
                exit 1
            }
        echo "memneq workaround was not needed for PKG_ARCH=$CURR_PACKAGE_ARCH. Create an issue at https://github.com/runfalk/synology-wireguard/issues/new/choose to let them know."
        echo
    fi
    sudo rm -f tmp.log
else
    # Update environment variables for existing build container and then run it
    echo "Found existing Docker container, updating environment variables"
    WG_ENV_VAR=$(sudo docker inspect --format '{{ index (index .Config.Env) }}' $WG_BUILDER_NAME | sed 's/\[//' | sed 's/\]//')
    WG_ENV_STRING=""
    for line in $WG_ENV_VAR; do
        if [[ $(echo $line | grep "WIREGUARD_VERSION=" | wc -l) -eq "1" ]]; then
            WG_ENV_STRING="$WG_ENV_STRING --env WIREGUARD_VERSION=$WIREGUARD_VERSION"
        elif [[ $(echo $line | grep "WIREGUARD_TOOLS_VERSION=" | wc -l) -eq "1" ]]; then
            WG_ENV_STRING="$WG_ENV_STRING --env WIREGUARD_TOOLS_VERSION=$WIREGUARD_TOOLS_VERSION"
        elif [[ $(echo $line | grep "LIBMNL_VERSION=" | wc -l) -eq "1" ]]; then
            WG_ENV_STRING="$WG_ENV_STRING --env LIBMNL_VERSION=$LIBMNL_VERSION"
        elif [[ $(echo $line | grep "HOSTNAME=" | wc -l) -eq "1" ]] || [[ $(echo $line | grep "HOME=" | wc -l) -eq "1" ]]; then
            :
        else
            WG_ENV_STRING="$WG_ENV_STRING --env $line"
        fi
    done
    echo "Running package build with existing Docker container..."
    sudo docker update $WG_ENV_STRING $WG_BUILDER_NAME
    sudo docker start -a $WG_BUILDER_NAME
fi
echo "Build complete, package created in $BASE_BUILD_PATH/"
echo

if [[ ! -z $INSTALL_WG ]]; then
    # Stop all started interfaces, then stop and uninstall WireGuard
    if [[ $(sudo synopkg list | grep Wire | wc -l) -gt "0" ]]; then
        WG_INTERFACES=$(sudo wg show | grep interface | sed 's/interface: //')
        if [[ ! -z $WG_INTERFACES ]]; then
            for val in $WG_INTERFACES; do
                echo "Stopping interface $val"
                sudo wg-quick down $val
            done
        fi
        echo "Stopping $INSTALLED_WIREGUARD_PACKAGE_NAME"
        sudo synopkg stop WireGuard
        echo "Uninstalling $INSTALLED_WIREGUARD_PACKAGE_NAME"
        sudo synopkg uninstall WireGuard
    fi

    # Install and start WireGuard package then start all interfaces that were previously started

    WG_INSTALL_FAIL_COUNT=0
    WG_INSTALL_FAILED=1
    until [[ -z $WG_INSTALL_FAILED ]]; do
        echo "Installing WireGuard"
        sudo synopkg install "$BASE_BUILD_PATH/WireGuard-$WIREGUARD_VERSION/WireGuard-$CURR_PACKAGE_ARCH-$WIREGUARD_VERSION.spk"
        if [[ $? -eq "1" ]] && [[ $WG_INSTALL_FAIL_COUNT -lt 10 ]]; then
            WG_INSTALL_FAILED=1
            echo "Trying again in ten seconds"
            sleep 10
            ((WG_INSTALL_FAIL_COUNT += 1))
        elif [[ $WG_INSTALL_FAIL_COUNT -eq 10 ]]; then
            echo "Unable to install SPK. Try downloading the SPK at this location using the DSM UI, and then do a Manual Install through Package Center. Assuming it works, you will have to start any shutdown interfaces (e.g. sudo wg-quick up wg0): $(pwd)/$BASE_BUILD_PATH/WireGuard-$WIREGUARD_VERSION/WireGuard-$CURR_PACKAGE_ARCH-$WIREGUARD_VERSION.spk"
            echo
            exit 1
        else
            echo "Installation Complete!"
            echo
            unset WG_INSTALL_FAILED
            unset WG_INSTALL_FAIL_COUNT
        fi
    done

    echo "Starting WireGuard"
    sudo synopkg start WireGuard
    if [[ ! -z $WG_INTERFACES ]]; then
        for val in $WG_INTERFACES; do
            startWireGuardInterface $val
        done
    else
        WG_INTERFACES=$(ls /etc/wireguard/*.conf)
        if [[ $(echo $WG_INTERFACES | wc -l) -gt "0" ]]; then
            while true; do
                read -p "No WireGuard interfaces were stopped during this run, but at least one interface definition was found in /etc/wireguard. Would you like to enable them now? [y/n] " yn
                case $yn in
                [Yy]*)
                    for val in $WG_INTERFACES; do
                        startWireGuardInterface $(basename $val ".conf")
                    done
                    break
                    ;;
                [Nn]*) break ;;
                *) echo "Please answer yes or no." ;;
                esac
            done
        fi
    fi
    echo
fi

if [[ -z $KEEP_WG_SPK ]]; then
    echo "Deleting built SPK files in $BASE_BUILD_PATH/WireGuard-$WIREGUARD_VERSION/"
    sudo rm -rf $BASE_BUILD_PATH/WireGuard-$WIREGUARD_VERSION/
fi

if [[ -z $KEEP_BUILD_ARTIFACTS ]]; then
    echo "Deleting $WG_BUILDER_NAME Docker image and container..."
    sudo docker container rm $WG_BUILDER_NAME
    sudo docker image rm $WG_BUILDER_NAME
    echo "Deleting persisted volume $(toolkit_tarballs)"
    sudo rm -rf $BASE_BUILD_PATH/toolkit_tarballs
    echo "All builder artifacts deleted"
    echo
else
    echo "Keeping $WG_BUILDER_NAME builder artifacts for next time"
    echo
fi

if [[ ! -z $SWITCH_BRANCH ]]; then
    echo "Switching $GIT_PATH back to $GIT_CURRENT_BRANCH branch"
    cd "$BASE_BUILD_PATH/$GIT_PATH"
    git checkout $GIT_CURRENT_BRANCH
    if [[ ! -z $IS_DIRTY ]]; then
        echo "Restoring unsaved changes to git repo"
        git stash pop
    fi
    cd ../..
    echo
fi

echo "DONE"
