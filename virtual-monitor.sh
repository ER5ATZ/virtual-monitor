#!/bin/bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_name="$(basename "${BASH_SOURCE[0]}")"
alias virtual-monitor=". '$script_dir/$script_name'"

my_hostname='virtualmonitor'

install_dependencies() {
    echo "Installing dependencies..."
    package_manager=""
    if command -v apt &> /dev/null; then
        sudo apt update
        package_manager="apt"
    elif command -v apt-get &> /dev/null; then
        sudo apt-get update
        package_manager="apt-get"
    else
        error_package
    fi

    install_package() {
        package=$1
        if ! command -v "$package" &> /dev/null; then
            echo "$package is not installed. Installing..."
            if [ "$package_manager" == "apt" ]; then
                sudo apt install -y "$package"
            elif [ "$package_manager" == "apt-get" ]; then
                sudo apt-get install -y "$package"
            else
                error_package
            fi
        fi
    }

    install_package avahi-daemon
    install_package x11vnc
    install_package ffmpeg
    install_package nginx

    set_hostname
}

set_hostname() {
    echo "Setting hostname..."
    hostname_controller=""
    current_hostname="$my_hostname"
    if command -v hostnamectl &> /dev/null; then
        hostname_controller="hostnamectl"
        current_hostname=$(hostnamectl --static)
    elif [ -f /etc/hostname ]; then
        hostname_controller="hostname"
        current_hostname=$(cat /etc/hostname)
    else
        error_host
    fi

    if [ "$current_hostname" == "localhost" ]; then
        echo "Setting hostname to $my_hostname"
        if [ "$hostname_controller" == "hostnamectl" ]; then
          sudo hostnamectl set-hostname "$my_hostname"
          sudo systemctl restart avahi-daemon
        elif [ "$hostname_controller" == "hostname" ]; then
          sudo hostname "$my_hostname"
          sudo systemctl restart avahi-daemon
        else
          error_host
        fi
    else
        my_hostname="$current_hostname"
    fi

    cat <<EOF | sudo tee /var/www/html/index.html
    <!DOCTYPE html>
    <html lang="en">
      <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>$my_hostname</title>
      </head>
      <body>
          <video width="100%" height="100%" controls>
              <source src="http://$my_hostname:8080/hls/stream.m3u8" type="application/x-mpegURL">
              Your browser does not support the video tag.
          </video>
      </body>
    </html>
    EOF

    sudo rm /etc/nginx/sites-available/default
    sudo rm /etc/nginx/sites-enabled/default

    cat <<EOF | sudo tee /etc/nginx/sites-available/$my_hostname
    server {
        listen 80 default_server;
        listen [::]:80 default_server;

        root /var/www/html;
        index index.html;

        server_name _;

        location / {
            try_files \$uri \$uri/ =404;
        }

        location /hls {
            types {
                application/vnd.apple.mpegurl m3u8;
                video/mp2t ts;
            }
            alias /tmp/hls;
            add_header Cache-Control no-cache;
        }
    }
    EOF

    sudo ln -s /etc/nginx/sites-available/$my_hostname /etc/nginx/sites-enabled/
    if command -v nginx &> /dev/null; then
        sudo systemctl restart nginx
    fi
}

start_stream() {
    check_dependencies

    x11vnc -clip 1920x1080+0+0 -nopw -xkb -noxrecord -noxfixes -noxdamage -display :0 -forever &
    ffmpeg -f x11grab -s 1920x1080 -framerate 30 -i :0.0+0,0 -c:v libx264 -preset ultrafast -tune zerolatency -hls_time 2 -hls_wrap 5 -start_number 0 /tmp/hls/stream.m3u8 &

    echo "Streaming is now available at http://$my_hostname/ or http://localhost/ (or any individual name you might have set)."
}

stop_stream() {
    pkill x11vnc
    pkill ffmpeg

    echo "Streaming stopped."
}

check_dependencies() {
    if ! command -v avahi-daemon &> /dev/null; then
        error_install "Avahi"
    elif ! command -v x11vnc &> /dev/null; then
        error_install "x11vnc"
    elif ! command -v ffmpeg &> /dev/null; then
        error_install "FFmpeg"
    elif ! command -v nginx &> /dev/null; then
        error_install "Nginx"
    fi

    current_hostname=""
    if command -v hostnamectl &> /dev/null; then
        current_hostname=$(hostnamectl --static)
    elif [ -f /etc/hostname ]; then
        current_hostname=$(cat /etc/hostname)
    else
        error_host
    fi

    if [ "$current_hostname" == "" || !("$current_hostname" == "localhost" || "$current_hostname" == "virtualmonitor") ]; then
        echo "Hostname is not set. Please run 'sudo virtual-monitor hostname' first."
        exit 1
    fi
}

check_sudo() {
    if [[ $EUID -ne 0 ]]; then
        echo "This command must be run with sudo. Please use 'sudo virtual-monitor <command>' instead."
        exit 1
    fi
}

help() {
    echo "Usage: ./$script_name {install|start|stop|help}"
    echo "  install        Install dependencies and set up the virtual monitor"
    echo "  host (<name>)  Set the hostname, default is virtualmonitor"
    echo "  check          Check if all dependencies are set up"
    echo "  start          Start the virtual monitor stream"
    echo "  stop           Stop the virtual monitor stream"
    echo "  help           Display this help message"
}

error_install() {
    echo "$1 is not installed. Please run 'sudo $script_name" install' first."
    exit 1
}

error_package() {
    echo "Neither 'apt' nor 'apt-get' commands found. Please install a package manager on your system."
    exit 1
}

error_host() {
    # Not a great solution, we may make the hostname optional later on and just go with the network IP
    echo "Please check your system configuration for the presence of 'hostnamectl' or '/etc/hostname'."
    echo "If neither is available, you may need to set the hostname manually somehow."
    exit 1
}

case "$1" in
    install)
        check_sudo
        install_dependencies
        ;;
    host)
        check_sudo
        set_hostname
        ;;
    host *)
        check_sudo
        my_hostname="${1:1}"
        set_hostname
        ;;
    check)
        check_dependencies
        ;;
    start)
        start_stream
        ;;
    stop)
        stop_stream
        ;;
    help)
        help
        ;;
    *)
        echo "Usage: $0 {install|host|check|start|stop|help}"
        exit 1
        ;;
esac

exit 0

}