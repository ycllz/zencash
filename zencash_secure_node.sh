#!/usr/bin/env bash

# IMPORTANT: Run this script from /home/<USER>/ directory: bash -c "$(curl SCRIPT_URL)"

# If there is nothing in crontab after running this script then:
# 1) crontab -e
# 2) add: @reboot /usr/bin/zend
# 3) add: 6 0 * * * "/home/<VM_USERNAME>/.acme.sh"/acme.sh --cron --home "/home/<VM_USERNAME>/.acme.sh" > /dev/null

# Quit on any error.
set -e
purpleColor='\033[0;95m'
normalColor='\033[0m'

# Set environment variables:
read -p "Enter Host Name (a.example.com): " HOST_NAME
if [[ $HOST_NAME == "" ]]; then
  echo "HOST name is required!"
  exit 1
fi

USER=$(whoami)

echo -e $purpleColor"Host name: $HOST_NAME\nUser name: $USER\n"$normalColor

########################################### packages ###########################################
sudo apt-get update && sudo apt-get -y upgrade
sudo apt -y install pwgen git ufw wget fail2ban rkhunter
sudo systemctl enable fail2ban
sudo systemctl start fail2ban

########################################### basic security ###########################################
sudo ufw default allow outgoing
sudo ufw default deny incoming
sudo ufw allow ssh/tcp
sudo ufw limit ssh/tcp
sudo ufw allow http/tcp
sudo ufw allow https/tcp
sudo ufw allow 9033/tcp 	#mainnet
#sudo ufw allow 19033/tcp 	#testnet
sudo ufw logging on
sudo ufw --force enable

echo -e $purpleColor"Basic security completed!"$normalColor

########################################### Add a swapfile. ###########################################
if [ $(cat /proc/swaps | wc -l) -lt 2 ]; then
  echo "Configuring your swapfile..."
  sudo fallocate -l 4G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo "/swapfile   none    swap    sw    0   0" | sudo tee --append /etc/fstab > /dev/null
else
  echo "Swapfile exists. Skipping."
fi
echo "vm.swappiness=10" | sudo tee --append /etc/sysctl.conf > /dev/null

echo -e $purpleColor"Swapfile is done!"$normalColor

########################################### Create an empty zen config file and add new config settings. ###########################################
if [ -f /home/$USER/.zen/zen.conf ]; then
  sudo rm /home/$USER/.zen/zen.conf || true
fi
echo "Creating an empty ZenCash config..."
sudo mkdir -p /home/$USER/.zen || true
sudo touch /home/$USER/.zen/zen.conf

RPC_USERNAME=$(pwgen -s 16 1)
RPC_PASSWORD=$(pwgen -s 64 1)

sudo sh -c "echo '
addnode=$HOST_NAME
addnode=zennodes.network
rpcuser=$RPC_USERNAME
rpcpassword=$RPC_PASSWORD
rpcport=18231
rpcallowip=127.0.0.1
server=1
daemon=1
listen=1
txindex=1
logtimestamps=1
onlynet=ipv4
# ssl
tlscertpath=/home/$USER/.acme.sh/$HOST_NAME/$HOST_NAME.cer
tlskeypath=/home/$USER/.acme.sh/$HOST_NAME/$HOST_NAME.key
### testnet config
#testnet=1
' >> /home/$USER/.zen/zen.conf"

echo -e $purpleColor"zen.conf is done!"$normalColor

########################################### ssl-certificate: ###########################################
if [ ! -d /home/$USER/acme.sh ]; then
  sudo apt install socat
  cd /home/$USER && git clone https://github.com/Neilpang/acme.sh.git
  cd /home/$USER/acme.sh && ./acme.sh --install
  sudo chown -R $USER:$USER /home/$USER/.acme.sh
fi
if [ ! -f /home/$USER/.acme.sh/$HOST_NAME/ca.cer ]; then
  sudo /home/$USER/.acme.sh/acme.sh --issue --standalone -d $HOST_NAME --home /home/$USER/.acme.sh
fi
cd ~
sudo cp /home/$USER/.acme.sh/$HOST_NAME/ca.cer /usr/local/share/ca-certificates/$HOST_NAME.crt
sudo update-ca-certificates
CRONCMD_ACME="6 0 * * * \"/home/$USER/.acme.sh\"/acme.sh --cron --home \"/home/$USER/.acme.sh\" > /dev/null" && (crontab -l | grep -v -F "$CRONCMD_ACME" ; echo "$CRONCMD_ACME") | crontab -

echo -e $purpleColor"certificates has been installed!"$normalColor

########################################### Installing zen: ###########################################
echo "BUILD FROM REPO:"
if ! [ -x "$(command -v zend)" ]; then
  sudo apt-get install apt-transport-https lsb-release dirmngr -y
  echo 'deb https://zencashofficial.github.io/repo/ '$(lsb_release -cs)' main' | sudo tee --append /etc/apt/sources.list.d/zen.list
  gpg --keyserver ha.pool.sks-keyservers.net --recv 219F55740BBF7A1CE368BA45FB7053CE4991B669
  gpg --export 219F55740BBF7A1CE368BA45FB7053CE4991B669 | sudo apt-key add -

  sudo apt-get update
  sudo apt-get install zen -y

  sudo chown -R $USER:$USER /home/$USER/.zen
  zen-fetch-params
fi

echo -e $purpleColor"Zen installation is finished!"$normalColor

########################################### run znode and sync chain on startup of VM: ###########################################

CRONCMD="@reboot /usr/bin/zend" && (crontab -l | grep -v -F "$CRONCMD" ; echo "$CRONCMD") | crontab -

########################################### secnodetracker ###########################################
if [ ! -d /home/$USER/zencash ]; then
  mkdir /home/$USER/zencash
fi

#Ubuntu
#sudo apt -y install npm
#sudo npm install -g n
#sudo n latest
#sudo npm install pm2 -g
#if [ ! -d /home/$USER/secnodetracker ]; then
#  cd /home/$USER && git clone https://github.com/ZencashOfficial/secnodetracker.git
#  cd /home/$USER/secnodetracker && npm install
#fi

#Debian
sudo apt -y install curl
curl -sL https://deb.nodesource.com/setup_8.x | sudo -E bash -
sudo apt -y install nodejs
sudo npm install pm2 -g
if [ ! -d /home/$USER/secnodetracker ]; then
  cd /home/$USER && git clone https://github.com/ZencashOfficial/secnodetracker.git
  cd /home/$USER/secnodetracker && npm install
fi

echo -e $purpleColor"Secnodetracker has been installed!"$normalColor

########################################### monit ###########################################
sudo apt install monit
cd /home/$USER && wget -O zen_node.sh 'https://raw.githubusercontent.com/lemmos/zencash/master/znode_start.sh'
sed -i -- "s/<USER>/$USER/g" /home/$USER/zen_node.sh
chmod u+x /home/$USER/zen_node.sh
sudo sh -c "echo '
### added on setup for zend
set httpd port 2812
use address localhost # only accept connection from localhost 
allow localhost # allow localhost to connect to the server
#
### zend process control
check process zend with pidfile /home/$USER/.zen/zen_node.pid
start program = \"/home/$USER/zen_node.sh start\" with timeout 60 seconds
stop program = \"/home/$USER/zen_node.sh stop\"
' >> /etc/monit/monitrc"
sudo monit reload

echo -e $purpleColor"Monit has been installed!"$normalColor

########################################### upgrade_script ###########################################
sudo sh -c "echo '
#!/bin/bash
sudo apt update
sudo apt dist-upgrade -y
sudo apt autoremove -y
sudo rkhunter --propupd
' >> /home/$USER/upgrade_script.sh"
sudo chmod u+x /home/$USER/upgrade_script.sh
sudo /home/$USER/upgrade_script.sh

########################################### Useful commands ###########################################
echo ""
echo "##########################################################################################"
echo ""
echo "Check totalbalance: zen-cli z_gettotalbalance"
echo "Get new address: zen-cli z_getnewaddress"
echo "List all addresses: zen-cli z_listaddresses"
echo "Get network info: zen-cli getnetworkinfo. Make sure 'tls_cert_verified' is true."
echo ""
echo "##########################################################################################"
echo ""
echo "Deposit 5 x 0.2 ZEN in private address within VPS"
echo "Run in /home/$USER/secnodetracker/ the following commands:"
echo "node setup.js"
echo "node app.js"
echo "pm2 start app.js --name securenodetracker"
echo "pm2 startup"
echo "You will have to copy and paste a command to get pm2 to start on boot – it tells you what to do"
echo "Run sudo monit start zend"
echo ""
echo "##########################################################################################"
echo ""
echo "Reboot your server and check that everything comes back up and starts running again."
echo "After it reboots, reconnect, and check things are working:"
echo "sudo monit status"
echo "pm2 status"
echo "zen-cli getinfo"
echo "zen-cli getnetworkinfo"
echo "ALL DONE! "
echo ""
echo "##########################################################################################"
echo ""
