import subprocess
import re

def run_command(command):
    """Run a shell command and return its output."""
    result = subprocess.run(command, shell=True, capture_output=True, text=True)
    if result.returncode != 0:
        raise Exception(f"Command failed: {command}\nError: {result.stderr}")
    return result.stdout

def parse_lsblk_output(output):
    """Parse the output of lsblk command to get disk and LVM details."""
    pattern = re.compile(r'^\s*(\S+)\s+(\S*)\s+(\d+:\d+:\d+:\d+)\s+(\d+\.?\d*\w*)\s+(\S+)', re.MULTILINE)
    matches = pattern.findall(output)
    disk_info = []
    for match in matches:
        name, mountpoint, hctl, size, disk_type = match
        disk_info.append({
            "name": name,
            "mountpoint": mountpoint,
            "hctl": hctl,
            "size": size,
            "type": disk_type
        })
    return disk_info

def parse_lvdisplay_output(output):
    """Parse the output of lvdisplay command to get LVM details."""
    lv_pattern = re.compile(r'LV Path\s+(\S+)\nLV Name\s+(\S+)\nVG Name\s+(\S+)\nLV Size\s+(\S+)')
    lv_matches = lv_pattern.findall(output)
    lvm_info = []
    for match in lv_matches:
        lv_path, lv_name, vg_name, lv_size = match
        lvm_info.append({
            "lv_path": lv_path,
            "lv_name": lv_name,
            "vg_name": vg_name,
            "lv_size": lv_size
        })
    return lvm_info

def associate_lvm_to_disks(disk_info, lvm_info):
    """Associate LVM information with the disks they originate from."""
    for lvm in lvm_info:
        vg_name = lvm['vg_name']
        for disk in disk_info:
            if vg_name in disk['name']:
                lvm['disk_name'] = disk['name']
                lvm['hctl'] = disk['hctl']
                lvm['mountpoint'] = disk['mountpoint']
                break
    return lvm_info

def format_output(data):
    """Format the data as a pipe-separated string."""
    output = []
    for item in data:
        output.append(f"{item.get('disk_name', '')}|{item.get('lv_name', '')}|{item.get('mountpoint', '')}|{item.get('hctl', '')}|{item.get('lv_size', '')}|lvm")
    return "\n".join(output)

def main():
    try:
        lsblk_output = run_command("lsblk -o NAME,MOUNTPOINT,HCTL,SIZE,TYPE | egrep -v 'part|rom'")
        lvdisplay_output = run_command("lvdisplay")
        
        disk_info = parse_lsblk_output(lsblk_output)
        lvm_info = parse_lvdisplay_output(lvdisplay_output)
        
        associated_info = associate_lvm_to_disks(disk_info, lvm_info)
        
        formatted_output = format_output(associated_info)
        print(formatted_output)
    except Exception as e:
        print(f"An error occurred: {e}")

if __name__ == "__main__":
    main()
