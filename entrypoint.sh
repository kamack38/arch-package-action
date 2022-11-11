#!/bin/bash
set -o errexit -o pipefail -o nounset

# Set path
WORKPATH=$GITHUB_WORKSPACE/$INPUT_PATH
HOME=/home/builder
echo "::group::Copying files from $WORKPATH to $HOME/gh-action"

# Set path permision
cd $HOME
mkdir gh-action
cd gh-action
cp -rfv "$GITHUB_WORKSPACE"/.git ./
cp -fv "$WORKPATH"/* ./
echo "::endgroup::"

# Update pkgver
CURR_PKGVER=$(sed -n "s:^pkgver=\(.*\):\1:p" PKGBUILD)
echo "name=OLD_PKGVER::$CURR_PKGVER" >>"$GITHUB_OUTPUT"
if [[ -n $INPUT_PKGVER ]]; then
    echo "::group::Updating pkgver on PKGBUILD from $CURR_PKGVER to $INPUT_PKGVER"
    sed -i "s:^pkgver=.*$:pkgver=$INPUT_PKGVER:g" PKGBUILD
    git diff PKGBUILD
    echo "::endgroup::"
fi

# Update pkgrel
if [[ -n $INPUT_PKGREL ]]; then
    CURR_PKGREL=$(sed -n "s:^pkgrel=\(.*\):\1:p" PKGBUILD)
    echo "::group::Updating pkgrel on PKGBUILD from $CURR_PKGREL to $INPUT_PKGREL"
    sed -i "s:^pkgrel=.*$:pkgrel=$INPUT_PKGREL:g" PKGBUILD
    git diff PKGBUILD
    echo "::endgroup::"
fi

# Install depends using paru from aur
if [[ -n $INPUT_PARU ]]; then
    echo "::group::Making package using paru"
    paru -U --noconfirm
    echo "::endgroup::"
elif [[ -n $INPUT_FLAGS ]]; then
    echo "::group::Running makepkg with flags ($INPUT_FLAGS)"
    makepkg "$INPUT_FLAGS"
    echo "::endgroup::"
fi
NEW_PKGVER=$(sed -n "s:^pkgver=\(.*\):\1:p" PKGBUILD)
echo "name=NEW_PKGVER::$NEW_PKGVER" >>"$GITHUB_OUTPUT"

# Update checksums
if [[ $INPUT_UPDPKGSUMS == true ]]; then
    echo "::group::Updating checksums on PKGBUILD"
    find . -maxdepth 1 -type f -not \( -name 'PKGBUILD' -or -name '*.install' \) -delete
    updpkgsums
    git diff PKGBUILD
    echo "::endgroup::"
fi

# Generate .SRCINFO
if [[ $INPUT_SRCINFO == true ]]; then
    echo "::group::Generating new .SRCINFO based on PKGBUILD"
    makepkg --printsrcinfo >.SRCINFO
    git diff .SRCINFO
    echo "::endgroup::"
fi

# Validate with namcap
if [[ $INPUT_NAMCAP == true ]]; then
    echo "::group::Validating PKGBUILD with namcap"
    namcap -i PKGBUILD
    echo "::endgroup::"
fi

echo "::group::Copying files from $HOME/gh-action to $WORKPATH"
sudo cp -fv PKGBUILD "$WORKPATH"/PKGBUILD
if [[ -e .SRCINFO ]]; then
    sudo cp -fv .SRCINFO "$WORKPATH"/.SRCINFO
fi
echo "::endgroup::"

if [[ -n $INPUT_AUR_PKGNAME && -n $INPUT_AUR_SSH_PRIVATE_KEY && -n $INPUT_AUR_COMMIT_EMAIL && -n $INPUT_AUR_COMMIT_USERNAME ]]; then
    if [[ "$INPUT_AUR_COMMIT_MESSAGE" == "" ]]; then
        INPUT_AUR_COMMIT_MESSAGE="Update $INPUT_AUR_PKGNAME to $NEW_PKGVER"
    fi

    echo '::group::Initializing SSH directory'
    mkdir -pv $HOME/.ssh
    touch $HOME/.ssh/known_hosts
    cp -v /ssh_config $HOME/.ssh/config
    echo '::endgroup::'

    echo '::group::Adding aur.archlinux.org to known hosts'
    ssh-keyscan -v -t 'rsa,dsa,ecdsa,ed25519' aur.archlinux.org >>~/.ssh/known_hosts
    echo '::endgroup::'

    echo '::group::Importing private key'
    echo "$INPUT_AUR_SSH_PRIVATE_KEY" >~/.ssh/aur
    chmod -vR 600 ~/.ssh/aur*
    ssh-keygen -vy -f ~/.ssh/aur >~/.ssh/aur.pub
    echo '::endgroup::'

    echo '::group::Checksums of SSH keys'
    sha512sum ~/.ssh/aur ~/.ssh/aur.pub
    echo '::endgroup::'

    echo '::group::Configuring Git'
    git config --global user.name "$INPUT_AUR_COMMIT_USERNAME"
    git config --global user.email "$INPUT_AUR_COMMIT_EMAIL"
    echo '::endgroup::'

    echo '::group::Cloning AUR package into /tmp/aur-repo'
    git clone -v "https://aur.archlinux.org/${INPUT_AUR_PKGNAME}.git" /tmp/aur-repo
    echo '::endgroup::'

    echo "::group::Copying files into /tmp/aur-repo"
    cp -fva "$WORKPATH/." /tmp/aur-repo
    echo '::endgroup::'

    echo '::group::Committing files to the repository'
    cd /tmp/aur-repo
    git add --all
    git diff-index --quiet HEAD || git commit -m "$INPUT_AUR_COMMIT_MESSAGE" # use `git diff-index --quiet HEAD ||` to avoid error
    echo '::endgroup::'

    echo '::group::Listing files in the repository'
    ls -al
    echo '::endgroup::'

    echo '::group::Publishing the repository'
    git remote add aur "ssh://aur@aur.archlinux.org/${INPUT_AUR_PKGNAME}.git"
    case "$INPUT_AUR_FORCE_PUSH" in
    true)
        git push -v --force aur master
        ;;
    false)
        git push -v aur master
        ;;
    *)
        echo "::error::Invalid Value: inputs.force_push is neither 'true' nor 'false': '$force_push'"
        exit 3
        ;;
    esac
    echo '::endgroup::'
fi
