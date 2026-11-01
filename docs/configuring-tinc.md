<!--
SPDX-FileCopyrightText: 2020 Aaron Raimist
SPDX-FileCopyrightText: 2020 Chris van Dijk
SPDX-FileCopyrightText: 2020 Dominik Zajac
SPDX-FileCopyrightText: 2020 Mickaël Cornière
SPDX-FileCopyrightText: 2020 Scott Crossen
SPDX-FileCopyrightText: 2020-2024 MDAD project contributors
SPDX-FileCopyrightText: 2020-2024 Slavi Pantaleev
SPDX-FileCopyrightText: 2022 François Darveau
SPDX-FileCopyrightText: 2022 Julian Foad
SPDX-FileCopyrightText: 2022 Warren Bailey
SPDX-FileCopyrightText: 2023 Antonis Christofides
SPDX-FileCopyrightText: 2023 Felix Stupp
SPDX-FileCopyrightText: 2023 Pierre 'McFly' Marty
SPDX-FileCopyrightText: 2024-2026 Suguru Hirahara
SPDX-FileCopyrightText: 2024-2026 spatterlight

SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Setting up tinc

This is an [Ansible](https://www.ansible.com/) role which installs [tinc](https://www.tinc-vpn.org/) to run as a [Docker](https://www.docker.com/) container wrapped in a systemd service.

tinc is a VPN daemon which joins nodes into one network. Nodes relay traffic for each other, and exchange it directly wherever they can reach each other. The container image used by this role is built from this role's [`Dockerfile`](../Dockerfile), and runs tinc 1.0.

See the project's [documentation](https://www.tinc-vpn.org/documentation/) to learn what tinc does and why it might be useful to you.

## Adjusting the playbook configuration

To enable tinc with this role, add the following configuration to your `vars.yml` file.

**Note**: the path should be something like `inventory/host_vars/mash.example.com/vars.yml` if you use the [MASH Ansible playbook](https://github.com/mother-of-all-self-hosting/mash-playbook).

```yaml
########################################################################
#                                                                      #
# tinc                                                                 #
#                                                                      #
########################################################################

tinc_enabled: true

# The name of this node, as in `tinc_hosts`
tinc_name: alpha

# The whole contents of this node's private key file (see below)
tinc_private_key: |
  PRIVATE_KEY_HERE

# The address of this node in the VPN, and the VPN's range
tinc_interface_addresses:
  - 10.10.0.1/24

########################################################################
#                                                                      #
# /tinc                                                                #
#                                                                      #
########################################################################
```

### Generate the keys

Every node needs an RSA key pair. Generate one for each node with OpenSSL:

```sh
openssl genrsa -out rsa_key.priv 4096
openssl rsa -in rsa_key.priv -pubout
```

The private key goes into `tinc_private_key` on that node only, so consider storing it with [Ansible Vault](https://docs.ansible.com/projects/ansible/latest/vault_guide/vault.html). The public key goes into the node's entry in `tinc_hosts`. Existing keys of tinc 1.0.36 nodes (`BEGIN RSA PUBLIC KEY`) work as well.

### Describe the network

`tinc_hosts` lists every node of the network, this one included. Every node needs the same list, so it is easiest to define it once, in a `group_vars` file which applies to all of them.

```yaml
tinc_hosts:
  - name: alpha
    addresses:
      - alpha.example.com
    subnets:
      - 10.10.0.1/32
    public_key: |
      -----BEGIN PUBLIC KEY-----
      PUBLIC_KEY_OF_ALPHA_HERE
      -----END PUBLIC KEY-----
  - name: beta
    addresses:
      - beta.example.com
    subnets:
      - 10.10.0.2/32
    public_key: |
      -----BEGIN PUBLIC KEY-----
      PUBLIC_KEY_OF_BETA_HERE
      -----END PUBLIC KEY-----
```

See [`defaults/main.yml`](../defaults/main.yml) for what each entry takes.

### Select the network mode

By default the container runs in its own network, and the VPN interface only exists inside the container. For the host (and the networks behind it) to use the VPN, run the container with host networking:

```yaml
tinc_container_network: host
```

The VPN interface is then created on the host. The role does not touch the firewall, so open `655/tcp` and `655/udp` yourself. With the default network, the role publishes them on the host.

If you publish them on another host port with `tinc_container_host_bind_port_tcp` and `tinc_container_host_bind_port_udp`, add that port to the node's `addresses` (e.g. `alpha.example.com 6655`), so that the other nodes connect to it.

### Select the topology

- **Full mesh**: the default. Every node connects to every other node which has `addresses`.
- **Hub and spoke**: set `tinc_connect_to: [hub]` on the spokes and `tinc_connect_to: []` on the hub. Spokes still exchange traffic directly when they can reach each other. To make other nodes go through the hub for a spoke, add `IndirectData = yes` to the spoke's `additional_configuration`.
- **Nodes behind NAT**: leave out `addresses` for nodes which the others cannot reach. They connect to the others themselves.
- **Site-to-site**: add the network behind a node to its `subnets`, and route it on the other nodes with `tinc_interface_routes` (e.g. `192.168.2.0/24`). The node in front of the network needs host networking and IP forwarding enabled on its host.
- **Layer 2**: `tinc_mode: switch` forwards Ethernet frames instead of IP packets, so `subnets` are not needed. To bridge the VPN interface with a network of the host, add e.g. `ip link set "$INTERFACE" master br0` to `tinc_up_additional_commands`.

### Extending the configuration

There are some additional things you may wish to configure about the service.

Take a look at:

- [`defaults/main.yml`](../defaults/main.yml) for some variables that you can customize via your `vars.yml` file. Other [main configuration variables](https://www.tinc-vpn.org/documentation/Main-configuration-variables.html) can be set with `tinc_additional_configuration`, and other [host configuration variables](https://www.tinc-vpn.org/documentation/Host-configuration-variables.html) with `additional_configuration` in an entry of `tinc_hosts`.

## Installing

After configuring the playbook, run the installation command of your playbook as below:

```sh
ansible-playbook -i inventory/hosts setup.yml --tags=setup-all,start
```

If you use the MASH playbook, the shortcut commands with the [`just` program](https://github.com/mother-of-all-self-hosting/mash-playbook/blob/main/docs/just.md) are also available: `just install-all` or `just setup-all`

## Usage

After running the command for installation, tinc connects to the nodes in `tinc_connect_to` and accepts connections from the other nodes in `tinc_hosts`. To check the tunnel, ping the VPN address of another node (e.g. `ping 10.10.0.2`) from the host, or with `docker exec tinc ping 10.10.0.2` with the default network (or how you/your playbook named the container, e.g. `mash-tinc`).

## Troubleshooting

### Check the service's logs

You can find the logs in [systemd-journald](https://www.freedesktop.org/software/systemd/man/systemd-journald.service.html) by logging in to the server with SSH and running `journalctl -fu tinc` (or how you/your playbook named the service, e.g. `mash-tinc`).

To log the connections as well, raise the debug level:

```yaml
tinc_process_extra_arguments_custom:
  - --debug=1
```
