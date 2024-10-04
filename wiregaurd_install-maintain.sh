#!/bin/bash

# Modified version with improved security and error handling.

# Detect if the script is being run with bash
if [[ "$(readlink /proc/$$/exe)" != */bash ]]; then
    echo 'This installer needs to be run with "bash", not "sh".'
    exit 1
fi

# Discard stdin. Needed when running from a one-liner which includes a newline
read -N 999999 -t 0.001

# Ensure the script is run as root
if [[ "$EUID" -ne 0 ]]; then
    echo "This installer needs to be run with superuser privileges."
    exit 1
fi

# Ensure that sbin directories are in PATH
if ! echo "$PATH" | grep -q -E '(^|:)/sbin(:|$)'; then
    export PATH="$PATH:/sbin:/usr/sbin"
fi

# Detect OS
if [[ -e /etc/os-release ]]; then
    . /etc/os-release
    OS="$ID"
    VERSION_ID="${VERSION_ID%%.*}"
else
    echo "Cannot detect operating system."
    exit 1
fi

# Check if the OS is supported
if [[ "$OS" == "ubuntu" && "$VERSION_ID" -ge 22 ]]; then
    :
elif [[ "$OS" == "debian" && "$VERSION_ID" -ge 11 ]]; then
    :
elif [[ "$OS" =~ ^(centos|almalinux|rocky)$ && "$VERSION_ID" -ge 9 ]]; then
    :
elif [[ "$OS" == "fedora" && "$VERSION_ID" -ge 34 ]]; then
    :
else
    echo "Your operating system is not supported by this installer."
    exit 1
fi

# Function to validate IP addresses
validate_ip() {
    local ip=$1
    local stat=1

    if [[ $ip =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        if [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]; then
            stat=0
        fi
    fi
    return $stat
}

# Function to get the public IP
get_public_ip() {
    local ip
    ip=$(curl -s https://api.ipify.org)
    if validate_ip "$ip"; then
        echo "$ip"
    else
        echo ""
    fi
}

# Function to select DNS server
new_client_dns() {
    echo "Select a DNS server for the client:"
    echo "   1) Current system resolvers"
    echo "   2) Google"
    echo "   3) 1.1.1.1"
    echo "   4) OpenDNS"
    echo "   5) Quad9"
    echo "   6) AdGuard"
    read -p "DNS server [1]: " dns_choice
    until [[ -z "$dns_choice" || "$dns_choice" =~ ^[1-6]$ ]]; do
        echo "$dns_choice: invalid selection."
        read -p "DNS server [1]: " dns_choice
    done
    dns_choice=${dns_choice:-1}
    case "$dns_choice" in
        1)
            # Use system resolvers
            if [[ -f /etc/resolv.conf ]]; then
                dns=$(grep -v '#' /etc/resolv.conf | grep 'nameserver' | awk '{print $2}' | xargs | sed 's/ /, /g')
                if [[ -z "$dns" ]]; then
                    echo "No nameservers found in /etc/resolv.conf"
                    exit 1
                fi
            else
                echo "/etc/resolv.conf not found"
                exit 1
            fi
            ;;
        2)
            dns="8.8.8.8, 8.8.4.4"
            ;;
        3)
            dns="1.1.1.1, 1.0.0.1"
            ;;
        4)
            dns="208.67.222.222, 208.67.220.220"
            ;;
        5)
            dns="9.9.9.9, 149.112.112.112"
            ;;
        6)
            dns="94.140.14.14, 94.140.15.15"
            ;;
    esac
}

# Function to set up a new client
new_client_setup() {
    local client_name="$1"
    local client_ip="$2"
    local client_dns="$3"

    # Generate client keys
    client_private_key=$(wg genkey)
    client_public_key=$(echo "$client_private_key" | wg pubkey)
    client_psk=$(wg genpsk)

    # Add client to server configuration
    cat <<EOF >> /etc/wireguard/wg0.conf

# BEGIN_PEER $client_name
[Peer]
PublicKey = $client_public_key
PresharedKey = $client_psk
AllowedIPs = $client_ip/32
# END_PEER $client_name
EOF

    # Generate client configuration
    cat <<EOF > ~/"$client_name.conf"
[Interface]
PrivateKey = $client_private_key
Address = $client_ip/24
DNS = $client_dns

[Peer]
PublicKey = $server_public_key
PresharedKey = $client_psk
Endpoint = $public_ip:$port
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

    chmod 600 ~/"$client_name.conf" || { echo "Failed to set permissions on client config"; exit 1; }

    # Apply new peer configuration without restarting the interface
    wg set wg0 peer "$client_public_key" preshared-key <(echo "$client_psk") allowed-ips "$client_ip/32" || { echo "Failed to add client to WireGuard interface"; exit 1; }

    echo "Client $client_name added successfully."
    echo "Configuration available at ~/$client_name.conf"
}

# Main script logic

if [[ ! -e /etc/wireguard/wg0.conf ]]; then
    # Fresh installation
    echo "Starting WireGuard installation..."

    # Install WireGuard
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        apt-get update || { echo "apt-get update failed"; exit 1; }
        apt-get install -y wireguard qrencode || { echo "Failed to install WireGuard"; exit 1; }
    elif [[ "$OS" == "centos" || "$OS" == "almalinux" || "$OS" == "rocky" ]]; then
        yum install -y epel-release || { echo "Failed to install EPEL release"; exit 1; }
        yum install -y wireguard-tools qrencode || { echo "Failed to install WireGuard"; exit 1; }
    elif [[ "$OS" == "fedora" ]]; then
        dnf install -y wireguard-tools qrencode || { echo "Failed to install WireGuard"; exit 1; }
    fi

    # Detect public IP
    public_ip=$(get_public_ip)
    if [[ -z "$public_ip" ]]; then
        echo "Could not detect public IP."
        read -p "Enter public IP or hostname: " public_ip
    else
        echo "Detected public IP: $public_ip"
        read -p "Enter public IP or hostname [$public_ip]: " input_public_ip
        public_ip=${input_public_ip:-$public_ip}
    fi

    while [[ -z "$public_ip" ]]; do
        echo "Public IP or hostname cannot be empty."
        read -p "Enter public IP or hostname: " public_ip
    done

    # Ask for the listening port
    read -p "Enter WireGuard listening port [51820]: " port
    port=${port:-51820}
    while ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; do
        echo "Invalid port number."
        read -p "Enter WireGuard listening port [51820]: " port
        port=${port:-51820}
    done

    # Generate server keys
    server_private_key=$(wg genkey)
    server_public_key=$(echo "$server_private_key" | wg pubkey)
    if [[ -z "$server_private_key" || -z "$server_public_key" ]]; then
        echo "Failed to generate WireGuard keys."
        exit 1
    fi

    # Create WireGuard configuration directory
    mkdir -p /etc/wireguard || { echo "Failed to create /etc/wireguard directory"; exit 1; }
    chmod 700 /etc/wireguard

    # Create wg0.conf
    cat <<EOF >/etc/wireguard/wg0.conf
[Interface]
PrivateKey = $server_private_key
Address = 10.7.0.1/24
ListenPort = $port
EOF

    chmod 600 /etc/wireguard/wg0.conf || { echo "Failed to set permissions on /etc/wireguard/wg0.conf"; exit 1; }

    # Enable IP forwarding
    sysctl -w net.ipv4.ip_forward=1 || { echo "Failed to enable IPv4 forwarding"; exit 1; }
    echo 'net.ipv4.ip_forward=1' >/etc/sysctl.d/wg.conf

    # Set up firewall rules
    if command -v ufw >/dev/null 2>&1; then
        # Using UFW
        ufw allow "$port"/udp || { echo "Failed to add UFW rule"; exit 1; }
        ufw route allow in on wg0 out on eth0 || { echo "Failed to add UFW route rule"; exit 1; }
    elif command -v firewall-cmd >/dev/null 2>&1; then
        # Using firewalld
        firewall-cmd --add-port="$port"/udp --permanent || { echo "Failed to add firewalld port rule"; exit 1; }
        firewall-cmd --add-masquerade --permanent || { echo "Failed to enable masquerading in firewalld"; exit 1; }
        firewall-cmd --zone=public --add-interface=wg0 --permanent || { echo "Failed to add wg0 to firewalld"; exit 1; }
        firewall-cmd --reload || { echo "Failed to reload firewalld"; exit 1; }
    else
        # Using iptables
        iptables -A INPUT -p udp --dport "$port" -j ACCEPT || { echo "Failed to add iptables rule"; exit 1; }
        iptables -A FORWARD -i wg0 -j ACCEPT || { echo "Failed to add iptables FORWARD rule"; exit 1; }
        iptables -A FORWARD -o wg0 -j ACCEPT || { echo "Failed to add iptables FORWARD rule"; exit 1; }
        iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE || { echo "Failed to add iptables NAT rule"; exit 1; }
        # Save iptables rules
        if command -v iptables-save >/dev/null 2>&1; then
            iptables-save > /etc/iptables.rules || { echo "Failed to save iptables rules"; exit 1; }
            cat <<EOF >/etc/network/if-pre-up.d/iptables
#!/bin/sh
iptables-restore < /etc/iptables.rules
EOF
            chmod +x /etc/network/if-pre-up.d/iptables || { echo "Failed to set execute permission on iptables restore script"; exit 1; }
        else
            echo "iptables-save not found, iptables rules may not persist after reboot."
        fi
    fi

    # Enable and start WireGuard service
    systemctl enable wg-quick@wg0.service || { echo "Failed to enable WireGuard service"; exit 1; }
    systemctl start wg-quick@wg0.service || { echo "Failed to start WireGuard service"; exit 1; }

    # Ask for client name
    read -p "Enter a name for the client [client]: " client_name
    client_name=${client_name:-client}
    # Corrected the tr command by moving hyphen to the end
    client_name=$(echo "$client_name" | tr -c 'a-zA-Z0-9_-' '_')

    # Ensure client name is unique
    while grep -q "BEGIN_PEER $client_name\$" /etc/wireguard/wg0.conf; do
        echo "Client name $client_name already exists. Please choose another name."
        read -p "Enter a name for the client: " client_name
        client_name=$(echo "$client_name" | tr -c 'a-zA-Z0-9_-' '_')
    done

    # Assign client IP
    client_ip="10.7.0.2"

    # Select DNS
    new_client_dns

    # Set up new client
    new_client_setup "$client_name" "$client_ip" "$dns"

    echo "WireGuard installation and configuration complete."
else
    # WireGuard is already installed
    echo "WireGuard is already installed."
    echo
    echo "Select an option:"
    echo "   1) Add a new client"
    echo "   2) Remove an existing client"
    echo "   3) Remove WireGuard"
    echo "   4) Exit"
    read -p "Option: " option
    until [[ "$option" =~ ^[1-4]$ ]]; do
        echo "$option: invalid selection."
        read -p "Option: " option
    done
    case "$option" in
        1)
            # Add a new client
            echo "Enter a name for the client:"
            read -p "Name: " client_name
            # Corrected the tr command by moving hyphen to the end
            client_name=$(echo "$client_name" | tr -c 'a-zA-Z0-9_-' '_')
            while [[ -z "$client_name" || $(grep -c "BEGIN_PEER $client_name\$" /etc/wireguard/wg0.conf) -ne 0 ]]; do
                echo "Invalid or duplicate client name."
                read -p "Name: " client_name
                client_name=$(echo "$client_name" | tr -c 'a-zA-Z0-9_-' '_')
            done

            # Find next available IP
            last_ip=$(grep 'AllowedIPs' /etc/wireguard/wg0.conf | awk '{print $3}' | cut -d'/' -f1 | awk -F. '{print $4}' | sort -n | tail -n1)
            if [[ -z "$last_ip" ]]; then
                last_ip=2
            else
                last_ip=$((last_ip + 1))
            fi
            if [[ "$last_ip" -ge 255 ]]; then
                echo "No available IP addresses left."
                exit 1
            fi
            client_ip="10.7.0.$last_ip"

            # Select DNS
            new_client_dns

            # Retrieve server public key
            server_public_key=$(wg show wg0 public-key)

            # Retrieve public IP and port from existing configuration
            public_ip=$(grep 'Endpoint' ~/*.conf | head -n1 | awk '{print $3}' | cut -d':' -f1)
            port=$(grep 'ListenPort' /etc/wireguard/wg0.conf | awk '{print $3}')

            # Set up new client
            new_client_setup "$client_name" "$client_ip" "$dns"

            ;;
        2)
            # Remove an existing client
            number_of_clients=$(grep -c 'BEGIN_PEER' /etc/wireguard/wg0.conf)
            if [[ "$number_of_clients" -eq 0 ]]; then
                echo "No clients to remove."
                exit 0
            fi
            echo "Select the client to remove:"
            grep 'BEGIN_PEER' /etc/wireguard/wg0.conf | awk '{print NR") " $3}'
            read -p "Client number: " client_number
            until [[ "$client_number" =~ ^[0-9]+$ && "$client_number" -le "$number_of_clients" && "$client_number" -ge 1 ]]; do
                echo "Invalid selection."
                read -p "Client number: " client_number
            done
            client_name=$(grep 'BEGIN_PEER' /etc/wireguard/wg0.conf | awk '{print $3}' | sed -n "${client_number}p")
            read -p "Are you sure you want to remove client $client_name? [y/N]: " confirm
            confirm=${confirm:-N}
            if [[ "$confirm" =~ ^[yY]$ ]]; then
                # Remove from WireGuard config
                wg set wg0 peer $(grep -A 1 "BEGIN_PEER $client_name\$" /etc/wireguard/wg0.conf | grep 'PublicKey' | awk '{print $3}') remove
                # Remove from configuration file
                sed -i "/BEGIN_PEER $client_name\$/,/END_PEER $client_name\$/d" /etc/wireguard/wg0.conf
                echo "Client $client_name removed."
            else
                echo "Operation cancelled."
            fi
            ;;
        3)
            # Remove WireGuard
            read -p "Are you sure you want to remove WireGuard? [y/N]: " confirm
            confirm=${confirm:-N}
            if [[ "$confirm" =~ ^[yY]$ ]]; then
                systemctl stop wg-quick@wg0.service || { echo "Failed to stop WireGuard service"; exit 1; }
                systemctl disable wg-quick@wg0.service || { echo "Failed to disable WireGuard service"; exit 1; }
                rm -f /etc/sysctl.d/wg.conf
                if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
                    apt-get remove --purge -y wireguard qrencode || { echo "Failed to remove WireGuard"; exit 1; }
                elif [[ "$OS" == "centos" || "$OS" == "almalinux" || "$OS" == "rocky" ]]; then
                    yum remove -y wireguard-tools qrencode || { echo "Failed to remove WireGuard"; exit 1; }
                elif [[ "$OS" == "fedora" ]]; then
                    dnf remove -y wireguard-tools qrencode || { echo "Failed to remove WireGuard"; exit 1; }
                fi
                rm -rf /etc/wireguard
                echo "WireGuard has been removed."
            else
                echo "Operation cancelled."
            fi
            ;;
        4)
            exit 0
            ;;
    esac
fi
