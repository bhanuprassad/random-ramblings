import subprocess
import json
import pandas as pd

def run_command(command):
    """Run a shell command and return its output."""
    result = subprocess.run(command, shell=True, capture_output=True, text=True)
    if result.returncode != 0:
        raise Exception(f"Command failed: {command}\nError: {result.stderr}")
    return result.stdout

def write_json_to_file(json_data, filename):
    """Write JSON data to a file."""
    with open(filename, 'w') as file:
        json.dump(json_data, file, indent=4)

def read_json_from_file(filename):
    """Read JSON data from a file."""
    with open(filename, 'r') as file:
        return json.load(file)

def parse_hctl(hctl):
    """Parse the HCTL value to extract SCSI channel and target."""
    if hctl:
        parts = hctl.split('.')
        if len(parts) >= 3:
            return parts[1], parts[2]  # Channel and Target
    return "", ""

def parse_lsblk_json(json_data):
    """Parse the JSON output of lsblk command to get disk and LVM details."""
    disk_info = []

    def extract_lvm_info(device, current_disk):
        """Recursively extract LVM information from device."""
        if 'children' in device:
            for child in device['children']:
                if child['type'] == 'lvm':
                    scsi_channel, scsi_target = parse_hctl(device.get('hctl', ""))
                    disk_info.append({
                        "Disk Name": current_disk,
                        "LVM Name": child.get('name', ""),
                        "Mountpoint": child.get('mountpoint', ""),
                        "HCTL": device.get('hctl', ""),
                        "SCSI Channel": scsi_channel,
                        "SCSI Target": scsi_target,
                        "Size": child.get('size', ""),
                        "Type": child.get('type', "")
                    })
                else:
                    extract_lvm_info(child, current_disk)

    for device in json_data['blockdevices']:
        if device['type'] == 'disk':
            current_disk = device['name']
            extract_lvm_info(device, current_disk)

    return disk_info

def write_to_csv(data, filename):
    """Write the data to a CSV file using pandas."""
    df = pd.DataFrame(data)
    df.to_csv(filename, sep='|', index=False)
    print(f"Data written to {filename}")

def main():
    try:
        # Get the JSON output from lsblk and write to a temp file
        lsblk_output = run_command("lsblk -J -o NAME,MOUNTPOINT,HCTL,SIZE,TYPE")
        lsblk_json = json.loads(lsblk_output)
        
        temp_json_file = 'lsblk_output.json'
        write_json_to_file(lsblk_json, temp_json_file)
        print(f"JSON output written to {temp_json_file}")

        # Read the JSON from the temp file and parse it
        json_data = read_json_from_file(temp_json_file)
        disk_info = parse_lsblk_json(json_data)
        print("Parsed disk info:", disk_info)  # Debugging line
        
        # Write the parsed data to CSV
        write_to_csv(disk_info, 'disk_lvm_info.csv')
        print("Output written to disk_lvm_info.csv")

    except Exception as e:
        print(f"An error occurred: {e}")

if __name__ == "__main__":
    main()
