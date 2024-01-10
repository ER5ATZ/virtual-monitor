# Virtual Monitor Streaming

virtual-monitor.sh is a bash script that sets up a virtual monitor stream using x11vnc, ffmpeg, and Nginx.

## Table of Contents

- [Installation](#installation)
- [Usage](#usage)
- [Commands](#commands)
- [Contributing](#contributing)
- [License](#license)

## Installation

1. Clone the repository:

    ```bash
    git clone https://github.com/ER5ATZ/virtual-monitor.git
    cd virtual-monitor
    ```

2. Make the script executable:

    ```bash
    sudo chmod +x ./virtual-monitor.sh
    ```

3. Run the installation:

    ```bash
    sudo ./virtual-monitor.sh install
    ```

## Usage

- Set a custom hostname (default is virtualmonitor):

    ```bash
    sudo ./virtual-monitor.sh host [hostname](optional)
    ```

- Start the virtual monitor stream:

    ```bash
    ./virtual-monitor.sh start
    ```

- Stop the virtual monitor stream:

    ```bash
    ./virtual-monitor.sh stop
    ```

- Check if all dependencies are set up:

    ```bash
    ./virtual-monitor.sh check
    ```

- Display the help message:

    ```bash
    ./virtual-monitor.sh help
    ```

## Commands

- **install**: Install dependencies and set up the virtual monitor.
- **host <name>**: Set the hostname. Default is virtualmonitor.
- **check**: Check if all dependencies are set up.
- **start**: Start the virtual monitor stream.
- **stop**: Stop the virtual monitor stream.
- **help**: Display this help message.

## Contributing

If you find any issues or have suggestions for improvement, feel free to open an issue or create a pull request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

