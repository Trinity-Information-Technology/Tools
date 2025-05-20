#!/bin/bash
MODPROBEFILE="/etc/modprobe.d/CIS.conf"
#MODPROBEFILE="/tmp/CIS.conf"
ANSWER=0

analyze_part () {
	if [ "$#" != "1" ]; then
		options="$(echo $@ | awk 'BEGIN{FS="[()]"}{print $2}')"
    	echo "[+]$@"
    	apply_part_rule $1

	else
		echo "[-]\"$1\" not in separated partition. Check section \"1.1 Filesystem Configuration\" in CIS Benchmark."
	fi    
}

apply_part_rule (){
	if [ "$1" == "/tmp" ]; then
		suggested="nodev nosuid noexec"
		echo "Suggested rule: $suggested"
		prompt "Do you want to apply suggested rule?"
		if [ "$ANSWER" == "1" ]; then
			cat > /etc/systemd/system/local-fs.target.wants/tmp.mount << "EOF"
			[Mount] 
			Options=mode=1777,strictatime,noexec,nodev,nosuid
EOF
			mount -o remount,nodev,nosuid,noexec /tmp
			mount | grep /tmp | awk '{print $6}'
			echo "[+]Rule applied"
		elif [ "$1" == "-1" ]; then
			echo "[-]No rule applied"
		fi
	elif [ "$1" == "/var/tmp" ]; then
		suggested="nodev nosuid noexec"
		echo "Suggested rule: $suggested"
		prompt "Do you want to apply suggested rule?"
		if [ "$ANSWER" == "1" ]; then
			echo YES
		elif [ "$1" == "-1"]; then
			echo NO
		fi
	elif [ "$1" == "/dev/shm" ]; then
		suggested="nodev nosuid noexec"
		echo "Suggested rule: $suggested"
		prompt "Do you want to apply suggested rule?"
		if [ "$ANSWER" == "1" ]; then
			echo YES
		elif [ "$1" == "-1" ]; then
			echo NO
		fi	
	elif [ "$1" == "/home" ]; then
		suggested="nodev"
		echo "Suggested rule: $suggested"
		prompt "Do you want to apply suggested rule?"
		if [ "$ANSWER" == "1" ]; then
			echo YES
		elif [ "$1" == "-1" ]; then
			echo NO
		fi
	fi
}

prompt (){
	while true; do
	    read -p "$1 [Y/n] " input
	    case $input in
	        [Yy]* ) ANSWER=1; break;;
	        [Nn]* ) ANSWER=-1; break;;
	        * ) echo "Invalid input...";;
	    esac
	done
}
prompt "Do you want to update system before continuing?"
if [ "$ANSWER" == "1" ]; then
	yum update
	echo "[+]Done"
fi
echo -e "\n[1]Initial Setup\n"
echo "Disable unused filesystems:"
cat > $MODPROBEFILE << "EOF"
install cramfs /bin/true
install freevxfs /bin/true
install jffs2 /bin/true
install hfs /bin/true
install hfsplus /bin/true
install squahfs /bin/true
install udf /bin/true
install vfat /bin/true
EOF

echo Following rules has been added to $MODPROBEFILE
cat $MODPROBEFILE
echo "[+]Done"

echo "Partition Check:"
particiones=(/tmp /var /var/tmp /var/log /var/log/audit /home /dev/shm)
for particion in ${particiones[*]}; do
	out="$(mount | grep $particion)" 
	analyze_part $particion $out 
done

echo "Sticky bit set on all world-writable directories"
out="$(df --local -P | awk {'if (NR!=1) print $6'} | xargs -I '{}' find '{}' -xdev -type d \( -perm -0002 -a ! -perm -1000 \) 2>/dev/null)"
if [ -z "$out"  ]; then
	echo "[+]Pass"
else
	echo "[-]Error"
	prompt "What to fix it?"
	if [ "$ANSWER" == "1" ]; then
		df --local -P | awk {'if (NR!=1) print $6'} | xargs -I '{}' find '{}' -xdev -type d -perm -0002 2>/dev/null | xargs chmod a+t
		echo "[+]Done"
	fi
fi
echo "Automounting disabled?"
out="$(systemctl is-enabled autofs)"
if [ "$out" == "disabled" ]; then
	echo "[+]Pass"
else
	echo "[-]Error"
	prompt "What to fix it?"
	if [ "$ANSWER" == "1" ]; then
		systemctl disable autofs
		echo "[+]Done"
	fi
fi
prompt "Show repo list?"
if [ "$ANSWER" == "1" ]; then
	yum repolist
	echo "[+]Done"
fi
echo "GPG Keys are configured"
out="$(rpm -q gpg-pubkey --qf '%{name}-%{version}-%{release} --> %{summary}\n')"
if [ "$out" == "package gpg-pubkey is not installed" ]; then
	echo "[-]Error"
else
	echo "[+]Pass"
fi

echo "Gpgcheck \"yum.conf\""
out="$(grep ^gpgcheck /etc/yum.conf)"
if [ "$out" == "gpgcheck=1" ]; then
	echo "[+]Pass"
else
	echo "[-]Error: Please edit \"/etc/yum.conf\" and set 'gpgcheck=1'."
fi

echo "Gpgcheck is globally activated?"
out="$(grep ^gpgcheck /etc/yum.repos.d/* | grep =0)"
if [ -z "$out" ]; then
	echo "[+]Pass"
else
	echo "[-]Error: Edit any failing files in \"/etc/yum.repos.d/*\" and set all instances of gpgcheck to '1'."
fi

echo "AIDE is installed"
out="$(rpm -q aide)"
if [ "$out" == "package aide is not installed" ]; then
	echo "[-]Error: $out"
	prompt "Want to install it?"
	if [ "$ANSWER" == "1" ]; then
	yum -y install aide
	echo "[+]Done: Configure AIDE as appropriate for your environment."
	fi
else
	echo "[+]Pass"
fi
prompt "Want to initialize AIDE?"
if [ "$ANSWER" == "1" ]; then
	aide --init
	mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
	echo "[+]Done"
fi

echo "Filesystem integrity is regularly checked"
out="$(crontab -u root -l | grep aide)"
if [[ $out = *"aide"* ]]; then
	echo "[+]Pass"
else
	echo "[-]Error"
	prompt "Want to add aide to cron job?"
	if [ "$ANSWER" == "1" ]; then
	(crontab -l 2>/dev/null; echo "0 5 * * * /usr/sbin/aide --check") | crontab -
	crontab -l
	echo "[+]Done"
	fi
fi

echo "Permissions on bootloader config"
echo "[*]Setting permissions"
chown root:root /boot/grub2/grub.cfg
chmod og-rwx /boot/grub2/grub.cfg
echo "[+]Done"

echo "Bootloader password"
out="$(grep "^GRUB2_PASSWORD" /boot/grub2/grub.cfg)"
if [ -z "$out" ]; then
	prompt "[-]No password set, do you want to set it up now?"
	if [ "$ANSWER" == 1 ]; then
		grub2-setpassword
		echo "[+]Done"
	fi
else
	echo "[+]Pass"
fi
out="$(grep /sbin/sulogin /usr/lib/systemd/system/rescue.service)"
rule="ExecStart=-/bin/sh -c \"/usr/sbin/sulogin; /usr/bin/systemctl --fail --no-block default\""
if [ "$out" == "$rule" ]; then
	out="$(grep /sbin/sulogin /usr/lib/systemd/system/emergency.service)"
	if [ "$out" == "$rule" ]; then
		echo "[+] Pass"
	fi
else
	echo "[-] Error: Check section \"1.4.3 Filesystem Configuration\" in CIS Benchmark."
fi
echo "Setting core dump security limits"
echo '* hard core 0' > /etc/security/limits.conf
echo "[+]Done"

echo "XD/NX support"
dmesg | grep NX | awk 'FNR==1 {print FILENAME, $0}'
echo "[+]Done"

echo "Address space layout randomization (ASLR)"
echo "kernel.randomize_va_space = 2" >> /etc/sysctl.conf
echo "kernel.randomize_va_space = 2" >> "/etc/sysctl.d/*"
sysctl -w kernel.randomize_va_space=2
sysctl kernel.randomize_va_space
echo "[+]Done"

echo "Prelink is disabled?"
out="$(rpm -q prelink)"
if [ "$out" == "package prelink is not installed" ]; then
	echo "[+]Pass"
else
	prompt "[-]Prelink is installed, want to uninstall it?"
	if [ "$ANSWER" == "1" ]; then
	prelink -ua
	yum remove prelink
	echo "[+]Done"
	fi
fi
#1.6 Mandatory Access Control to 1.7 Warning Banners
echo -e "\n[2] Services\n"

out="$(rpm -q xinetd)"
if [ "$out" == "package xinetd is not installed" ]; then
	echo "[*]$out: Installing..."
	yum -y install xinetd
	echo "[+]Done"
fi

echo "Disabling \"chargen\" services"
chkconfig chargen-dgram off
chkconfig chargen-stream off
echo "[+]Done"

echo "Disabling \"daytime\" services"
chkconfig daytime-dgram off
chkconfig daytime-stream off
echo "[+]Done"

echo "Disabling \"discard\" services"
chkconfig discard-dgram off
chkconfig discard-stream off
echo "[+]Done"

echo "Disabling \"echo\" services"
chkconfig echo-dgram off
chkconfig echo-stream off
echo "[+]Done"

echo "Disabling \"time\" services"
chkconfig time-dgram off
chkconfig time-stream off
echo "[+]Done"

echo "Disabling \"xinetd\""
systemctl disable xinetd
echo "[+]Done"

echo "Time synchronization"
out="$(rpm -q ntp)"
if [ "$out" == "package ntp is not installed" ]; then
	echo "[*]$out. Installing..."
	yum -y install ntp
	echo "[+]Done"
fi

echo "Setting ntp configuration..."
cat >> /etc/ntp.conf << "EOF"
restrict -4 default kod nomodify notrap nopeer noquery 
restrict -6 default kod nomodify notrap nopeer noquery
EOF
cat >> c << "EOF"
OPTIONS="-u ntp:ntp"
EOF
echo "[+]Done"

echo "X Window System not installed"
out="$(rpm -qa xorg-x11*)"
if [ -z "$out" ]; then
	echo "[+]Pass"
else
	echo "[-]Error: $out. Uninstalling..."
	yum remove xorg-x11*
fi

echo "[*]Disabling Avahi Server..."
systemctl disable avahi-daemon

echo "[*]Disabling CUPS..."
systemctl disable cups

echo "[*]Disabling DHCP Server..."
systemctl disable dhcpd

echo "[*]Disabling LDAP Server..."
systemctl disable slapd

echo "[*]Disabling NFS and RPC..."
systemctl disable nfs
systemctl disable nfs-server
systemctl disable rpcbind

echo "[*]Disabling DNS Server..."
systemctl disable named

echo "[*]Disabling FTP Server..."
systemctl disable vsftpd

echo "[*]Disabling HTTP Server..."
systemctl disable httpd

echo "[*]Disabling IMAP and POP3..."
systemctl disable dovecot

echo "[*]Disabling SAMBA..."
systemctl disable smb

echo "[*]Disabling HTTP Proxy..."
systemctl disable squid

echo "[*]Disabling SNMP..."
systemctl disable snmpd

echo "[*]Disabling SNMP..."
systemctl disable snmpd

echo "MTA local-only"
out="$(netstat -an | grep LIST | grep ":25[[:space:]]")"
if [ -z "$out" ]; then
	echo "[-]Error: Check section \"2.2.15 CIS Benchmark for remediation"
else
	echo "[+]Pass"
fi

echo "[*]Disabling NIS Server..."
systemctl disable ypserv

echo "[*]Disabling RSH Server..."
systemctl disable rsh.socket
systemctl disable rlogin.socket
systemctl disable rexec.socket

echo "[*]Disabling Telnet Server..."
systemctl disable telnet.socket

echo "[*]Disabling TFTP Server..."
systemctl disable tftp.socket

echo "[*]Disabling rsync service..."
systemctl disable rsyncd

echo "[*]Disabling talk Server..."
systemctl disable ntalk

echo "NIS client is not installed"
out="$(rpm -q ypbind)"
if [ "$out" == "package ypbind is not installed" ]; then
	echo "[+]Pass"
else
	echo "[-]Error: $out. Uninstalling..."
	yum remove ypbind
fi

echo "RSH client is not installed"
out="$(rpm -q rsh)"
if [ "$out" == "package rsh is not installed" ]; then
	echo "[+]Pass"
else
	echo "[-]Error: $out. Uninstalling..."
	yum remove rsh
fi

echo "Talk client is not installed"
out="$(rpm -q talk)"
if [ "$out" == "package talk is not installed" ]; then
	echo "[+]Pass"
else
	echo "[-]Error: $out. Uninstalling..."
	yum remove talk
fi

echo "Telnet client is not installed"
out="$(rpm -q telnet)"
if [ "$out" == "package telnet is not installed" ]; then
	echo "[+]Pass"
else
	echo "[-]Error: $out. Uninstalling..."
	yum remove telnet
fi

echo "LDAP client is not installed"
out="$(rpm -q openldap-clients)"
if [ "$out" == "package openldap-clients is not installed" ]; then
	echo "[+]Pass"
else
	echo "[-]Error: $out. Uninstalling..."
	yum remove openldap-clients
fi

echo -e "\n[3]Network Configuration\n"

echo "Network Parameters (Host Only)"

echo "Hardening Completed"
