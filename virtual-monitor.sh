#!/bin/bash

SUCCESS_MSG="All necessary packages are installed, hostname was set to "
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

    install_package avahi-daemon $package_manager
    install_package x11vnc $package_manager
    install_package pulseaudio $package_manager
    install_package ffmpeg $package_manager
    install_package nginx $package_manager

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
        current_hostname="localhost"
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

    HTML_MSG="
    <!DOCTYPE html>
    <html lang=\"en\">
    <head>
        <meta charset=\"UTF-8\">
        <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
        <title>$my_hostname stream</title>
    </head>
    <body>
        <div id=\"status\">Checking stream status...</div>
        <video width=\"100%\" height=\"100%\" controls id=\"videoPlayer\">
            <source src=\"http://$my_hostname:8080/hls/stream.m3u8\" type=\"application/x-mpegURL\">
            Your browser does not support the video tag.
        </video>

        <script>
            var video = document.getElementById('videoPlayer');
            var statusDiv = document.getElementById('status');

            function checkStreamStatus() {
                var xhr = new XMLHttpRequest();
                xhr.open('HEAD', 'http://$my_hostname:8080/hls/stream.m3u8', true);

                xhr.onload = function() {
                    if (xhr.status >= 200 && xhr.status < 300) {
                        // Stream is online
                        statusDiv.innerText = 'Stream is online';
                        video.style.display = 'block';
                    } else {
                        // Stream is offline
                        statusDiv.innerText = 'Stream is offline';
                        video.style.display = 'none';
                    }
                };

                xhr.onerror = function() {
                    // Stream is offline
                    statusDiv.innerText = 'Stream is offline';
                    video.style.display = 'none';
                };

                xhr.send();
            }

            setInterval(checkStreamStatus, 5000);
            checkStreamStatus();
        </script>
    </body>
    </html>
    "
    echo "$HTML_MSG" > tmp.file
    sudo rm /var/www/html/index.html
    cat <<EOF | sudo tee /var/www/html/index.html
    $HTML_MSG
EOF

    if diff -q tmp.file /var/www/html/index.html >/dev/null; then
        echo "Wrote index page to /var/www/html/index.html"
    else
        echo "Could not write to /var/www/html/index.html"
        exit 1
    fi
    rm tmp.file

    sudo rm /etc/nginx/sites-available/default
    sudo rm /etc/nginx/sites-enabled/default

  NGINX_MSG="
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
  "

  echo "$NGINX_MSG" > tmp.file
  sudo rm /etc/nginx/sites-available/$my_hostname
  cat <<EOF | sudo tee /etc/nginx/sites-available/$my_hostname
  $NGINX_MSG
EOF

    if diff -q tmp.file /etc/nginx/sites-available/$my_hostname >/dev/null; then
        echo "Wrote nginx config to /etc/nginx/sites-available/$my_hostname"
    else
        echo "Could not write to /etc/nginx/sites-available/$my_hostname"
        exit 1
    fi
    rm tmp.file

    sudo ln -s /etc/nginx/sites-available/$my_hostname /etc/nginx/sites-enabled/
    if command -v nginx &> /dev/null; then
        sudo systemctl restart nginx
    fi

    echo "Installation finished. Your hostname is $my_hostname"
}

start_stream() {
    current_hostname=$my_hostname
    dependencies_check=$(check_dependencies)
    if [[ $dependencies_check == $SUCCESS_MSG* ]]; then
        current_hostname=${dependencies_check##*$SUCCESS_MSG }
        current_hostname=${current_hostname%"."*}
    fi

    echo "Starting x11vnc..."
    x11vnc -clip 1920x1080+0+0 -nopw -xkb -noxrecord -noxfixes -noxdamage -display :0 -forever &
    x11vnc_status=$?
    x11vnc_pid=$!
    trap 'kill $x11vnc_pid' EXIT

    if [ $x11vnc_status -eq 0 ]; then
        echo "x11vnc started successfully with PID $x11vnc_pid. Waiting for FFmpeg to start..."
    else
        echo "Failed to start x11vnc. Exiting."
        exit 1
    fi

    echo "Starting FFmpeg..."
    ffmpeg -f x11grab -s 1920x1080 -framerate 30 -i :0.0+0,0 -f pulse -i default -c:v libx264 -c:a aac -preset ultrafast -tune zerolatency -hls_time 2 -hls_wrap 5 -start_number 0 /tmp/hls/stream.m3u8 > /tmp/ffmpeg.log 2>&1 &
    ffmpeg_status=$?
    ffmpeg_pid=$!
    trap 'kill $x11vnc_pid; kill $ffmpeg_pid' EXIT

    if [ $ffmpeg_status -eq 0 ]; then
        echo "FFmpeg started successfully with PID $ffmpeg_pid."
    else
        echo "Failed to start FFmpeg. Exiting."
        kill $x11vnc_pid
        kill $ffmpeg_pid
        exit 1
    fi

    echo "Streaming is now available at http://$current_hostname/ or http://<ip-address>/ (or any individual name you might have set)."
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

    current_hostname="localhost"
    if command -v hostnamectl &> /dev/null; then
        current_hostname=$(hostnamectl --static)
    elif [ -f /etc/hostname ]; then
        current_hostname=$(cat /etc/hostname)
    else
        error_host
    fi

    if [ "$current_hostname" == "" ] || [ "$current_hostname" == "localhost" ]; then
        echo "Hostname is not set. Please run 'sudo virtual-monitor hostname' first."
    else
        echo "$SUCCESS_MSG$current_hostname."
    fi
}

check_sudo() {
    if [[ $EUID -ne 0 ]]; then
        echo "This command must be run with sudo. Please use 'sudo $0 $1' instead."
        exit 1
    fi
}

install_package() {
        package=$1
        if ! command -v "$package" &> /dev/null; then
            echo "$package is not installed. Installing..."
            if [ "$2" == "apt" ]; then
                sudo apt install -y "$package"
            elif [ "$2" == "apt-get" ]; then
                sudo apt-get install -y "$package"
            else
                error_package
            fi
        fi
    }

help() {
    echo "Usage: $0 {install|host|check|start|stop|help}"
    echo "  install        Install dependencies and set up the virtual monitor"
    echo "  host (<name>)  Set the hostname, default is virtualmonitor"
    echo "  check          Check if all dependencies are set up"
    echo "  start          Start the virtual monitor stream"
    echo "  stop           Stop the virtual monitor stream"
    echo "  help           Display this help message"
}

error_install() {
    echo "$1 is not installed. Please run 'sudo $0 install' first."
    exit 1
}

error_package() {
    echo "Neither 'apt' nor 'apt-get' commands found. Please install a package manager on your system."
    exit 1
}

error_host() {
    echo "Please check your system configuration for the presence of 'hostnamectl' or '/etc/hostname'."
    echo "If neither is available, you may need to set the hostname manually somehow."
    echo "Meanwhile, you can still access the stream via http://<this machine's ip address in the network>."
}

case "$1" in
    install)
        check_sudo "install"
        install_dependencies
        ;;
    host)
        check_sudo "host"
        my_hostname="${2:$my_hostname}"
        set_hostname
        ;;
    check)
        check_dependencies
        ;;
    start)
        check_sudo "start"
        start_stream
        ;;
    stop)
        check_sudo "stop"
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
