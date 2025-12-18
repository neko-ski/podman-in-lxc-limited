--- [中文](https://github.com/neko-ski/podman-in-lxc-limited/blob/main/readme-zh.md)

## This Tutorial — Running Native Containers on an LXC-Restricted Kernel Server Environment (Example: Debian 13)

### Approach
Common reasons why LXC-restricted kernel servers cannot run native Docker include:

- Nested virtualization/allowed cgroup nesting is not enabled on the host machine;

- The cgroups version or cgroup driver does not meet the container's requirements (e.g., only cgroup v1 is available, but v2 is expected).

You can try using solutions that do not force these features (e.g., Podman + fuse-overlayfs), or change `cgroup_manager` to `systemd` (depending on environment feasibility).

---

### 0) One-Click Installation Script

```bash
apt update && apt install -y sudo curl && curl -L -o install.sh https://raw.githubusercontent.com/neko-ski/podman-in-lxc-limited/main/blob/main/install.sh && chmod +x install.sh && sudo ./install.sh && rm -f install.sh


```


## Verification on an Euserv IPv6-Only Server (Execute Commands Sequentially; Requires Root Privileges or sudo)

The following command examples are given in order; please execute them only if you accept the risks (overwriting `/etc` and `podman system reset -f` will clear data).

### 1) Update the system and install necessary packages

```bash
sudo apt update && sudo apt -y upgrade && sudo apt -y install dnf podman podman-docker docker-compose

# Update package index, upgrade the system, and install dnf, podman, podman-docker, and docker-compose (using sudo for non-root users)

```

---

### 2) Create /etc/containers and copy the configuration from the package template (this will overwrite existing files in /etc)

```bash
sudo mkdir -p /etc/containers

# Ensure the /etc/containers directory exists

sudo cp -a /usr/share/containers/containers.conf /etc/containers/containers.conf

# Copy containers.conf from the system package template to /etc (this will overwrite existing files)

sudo cp -a /usr/share/containers/storage.conf /etc/containers/storage.conf

# Copy storage.conf from the system package template to /etc (this will overwrite files with the same name)

```

---

### 3) Uncomment and Set Specific Values in the Three Configuration Files: containers, storage, and registries (edit in order and print results for verification)

```bash
sudo sed -i 's|^[[:space:]]*#\?[[:space:]]*cgroup_manager[[:space:]]*=.*|cgroup_manager = "systemd"|' /etc/containers/containers.conf

# Enable cgroup_manager = "systemd" in /etc/containers/containers.conf (uncomment and replace the entire line)

sudo sed -i 's|^[[:space:]]*#\?[[:space:]]*keyring[[:space:]]*=.*|keyring = false|' /etc/containers/storage.conf

# Uncomment keyring and set it to false in /etc/containers/storage.conf

sudo sed -i 's|^[[:space:]]*#\?[[:space:]]*mount_program[[:space:]]*=.*|mount_program = "/usr/bin/fuse-overlayfs"|' /etc/containers/storage.conf

# Uncomment mount_program and set it to "/usr/bin/fuse-overlayfs" in /etc/containers/storage.conf

sudo sed -i 's|^[[:space:]]*#\?[[:space:]]*unqualified-search-registries[[:space:]]*=.*|unqualified-search-registries = ["docker.io"]|' /etc/containers/registries.conf

# Uncomment unqualified-search-registries in /etc/containers/registries.conf and change example.com to docker.io

sudo grep -nE 'cgroup_manager|keyring|mount_program|unqualified-search-registries' /etc/containers/containers.conf /etc/containers/storage.conf /etc/containers/registries.conf

# Print three configuration entries for quick verification of the modified lines

```

> Explanation:

> - I wrote `cgroup_manager` in `containers.conf` (this is official practice and more likely to be...) Podman reads the data, while `keyring` and `mount_program` write to `storage.conf`.

> - `sed` uses POSIX `[[:space:]]`, compatible with GNU sed and BusyBox sed.

> - If a template **does not exist at all** (very rare), the above `sed` will not add that line; however, after copying the template from `/usr/share` to `/etc`, the template usually contains these entries, so `sed` will hit the target.

---

### 4) (Optional and Destructive) Reset Podman State — **Dangerous: Use with Caution**

```bash
sudo podman system reset -f

# Warning: This operation will delete Podman's containers, images, volumes, networks, and other data. Only perform this operation if you can accept the data being wiped.

```

---
### 5) Download and install the docker-compose binary (please ensure the version number exists first)

```bash
ver="PUT_DESIRED_VERSION_HERE" # For example, "v2.20.2"; please ensure this version exists on the release page first

# Set the docker-compose version string to download (please fill in according to the actual release)

curl -L -o docker-compose-linux-x86_64 "https://github.com/docker/compose/releases/download/${ver}/docker-compose-linux-x86_64"

# Download the specified version of the docker-compose binary to the current directory

sudo chmod +x docker-compose-linux-x86_64

# Grant executable permissions

sudo mv docker-compose-linux-x86_64 /usr/local/bin/docker-compose

# Move to /usr/local/bin and name it docker-compose (placed in PATH)

docker-compose -v

# Displays the docker-compose version, verifying successful installation

```

---

### 6) Create the docker group and user (error handling: try not to report errors if the group or user already exists)

```bash

sudo groupadd -f docker

# Create the docker group; if it already exists, no error will be reported

sudo useradd -m -u 1000 docker_usr || true

# Create the user docker_usr with uid=1000 and create its home directory; ignore errors if the user already exists

sudo usermod -aG docker,sudo,podman docker_usr

# Add docker_usr to the docker, sudo, and podman groups (append, do not remove existing groups)

```

---

### 7) Enable podman socket (system and user methods, user) (Requires execution within a login session)

```bash

sudo systemctl enable --now podman.socket

# Enable system-wide podman.socket and start it immediately

systemctl --user enable --now podman.socket || true

# Attempt to enable podman.socket for the current user (this command may fail if not in a login session, hence the addition of || true)

```

---

### 8) Set the DOCKER_HOST environment variable (writes to the user's shell configuration and loads it immediately)

```bash

touch ~/.bash_profile

# Ensure ~/.bash_profile exists

echo 'export DOCKER_HOST=unix:///run/user/1000/docker.sock' >> ~/.bash_profile

# Append DOCKER_HOST to the user's ~/.bash_profile

source ~/.bash_profile

# Immediately in the current shell Load (If you are executing this step under a script or sudo, it may run as a different user; please execute it manually as needed)

```

---

### 9) Create a socket symbolic link so that clients that depend on /var/run/docker.sock can access the podman socket

```bash
sudo ln -sf /run/user/1000/podman/podman.sock /var/run/docker.sock

# Link the podman socket to /var/run/docker.sock (overriding)

sudo ln -sf /run/user/1000/podman/podman.sock /run/user/0/docker.sock

# Create a link for the root user (overriding)

ln -sf /run/user/1000/podman/podman.sock /run/user/1000/docker.sock

# Create a link for a regular user session (no need) sudo (when executed under the same user)

```

---

### 10) (Nonstandard Hack) Replace Podman's systemd Unit with docker.service (**Caution**)

```bash
sudo cp /lib/systemd/system/podman.service /etc/systemd/system/docker.service

# Copy podman.service and rename it to docker.service (place it in /etc to override the system unit), this is a hack

sudo cp /lib/systemd/system/podman.socket /etc/systemd/system/docker.socket

# Same as above, copy podman.socket to docker.socket

sudo systemctl daemon-reload

# Reload the systemd configuration to make the copied unit effective

sudo systemctl enable --now docker.service

# Enable and start docker.service immediately (actually podman's) (unit); may conflict with system expectations or the control panel, use with caution.
```

### 11) Check Service Status and Version

```bash
systemctl status docker.service

# Check the running status of docker.service (replaced with podman unit)

sudo docker -v

# Check the Docker client version (if any)

sudo docker-compose -v

# Check the docker-compose version

sudo podman -v

# Check the podman version
```


## Important Notes (Please read carefully)

1. **Overwriting `/etc/containers`:** The above command `cp -a /usr/share/containers/* /etc/containers/` will overwrite files with the same name under `/etc`, and any previously customized configurations will be lost. Please ensure you accept this overwriting behavior.

2. **Destructive nature of podman reset:** `podman system reset -f` will delete container, image, volume, and other data. If you need to retain data, do not execute `reset`, or export a backup first.

3. **Configuration Implementation Order (Priority)**: Rootless Podman prioritizes `~/.config/containers/*.conf` files, which override `/etc` configurations. If you are running Podman as a non-root user, please also check and modify the configuration files in your user directory.

4. **Correct Location of cgroup_manager**: `cgroup_manager` should typically be set in `containers.conf`. Podman may not read changes made only in `storage.conf`, so this revision adds it to `containers.conf` to ensure it takes effect.

5. **sed Compatibility**: I used POSIX's `[[:space:]]` for compatibility with common sed implementations (including BusyBox sed).

6. **Systemd Unit Hack Risks:** Copying podman's systemd unit and naming it `docker.service` is a workaround, which may not fully match the expected Docker behavior of control panels or other software (especially regarding socket names, environment variables, PIDs, and startup parameters). If you are using a control panel (such as 1Panel), it is recommended to verify this in a test environment first.

---

Source: [neko-ski/podman-in-lxc-limited](https://github.com/neko-ski/podman-in-lxc-limited) (please cite the source when reprinting)

Credits: Ideas by aspnmy — https://github.com/aspnmy/1Panel_Bt_in_podman_rootless
