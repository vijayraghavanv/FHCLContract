#!/bin/bash
if [ $# -lt 7 ]; then
  echo "############################################Invalid number of arguments######################################################"
  echo "Usage:"
  echo "setupBlockChainNetwork BlockChainName BlockchainVersion OrgChoice primaryOrgName secondaryOrgName channelName channelProfile primaryOrgIP"
  echo "e.g. setupBlockchainBasics myBC 1.1.0-preview 1 acme xyz mychannel"
  echo "BlockChainName: Name for this blockchain."
  echo "BlockChainVersion: Version for the blockchain that will be downloaded."
  echo "OrgChoice: This setup is for 2 organizations. Use 1 for primary and 2 for secondary"
  echo "primaryOrgName: The primary organization's name."
  echo "secondaryOrgName: The name of the second org that will particpate in this blockchain"
  echo "channelName: Name of the channel"
  echo "channelProfile: Profile name for creation of configtx. Note : this assumes that genesis block will use a genesis profile"

  exit 1
fi
export ARCH=$(echo "$(uname -s|tr '[:upper:]' '[:lower:]'|sed 's/mingw64_nt.*/windows/')-$(uname -m | sed 's/x86_64/amd64/g')" | awk '{print tolower($0)}')
#Set MARCH variable i.e ppc64le,s390x,x86_64,i386
BCName=$1
VERSION=$2
OrgChoice=$3
primaryOrgName=$4
secondaryOrgName=$5
channelName=$6
channelProfile=$7
primaryOrgIP=$8
IP_ADDRESS=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)
echo "Debug: Local IP address is : $IP_ADDRESS"
setEnvVariables(){
  if [[ ! ${FABRIC_HOME+x} ]]; then
    echo 'export FABRIC_HOME=$HOME/fabric' >>~/.profile
    FABRIC_HOME=$HOME/fabric
  fi
  if [[ ! ${FABRIC_CFG_PATH+x} ]]; then
    echo 'export FABRIC_CFG_PATH=/home/ubuntu/fabric/config' >> ~/.profile
    FABRIC_CFG_PATH=/home/ubuntu/fabric/config
  fi
  if [[ ! ${CHANNEL_NAME+x} ]]; then
    echo 'export CHANNEL_NAME="$channelName"' >> ~/.profile
    CHANNEL_NAME=$channelName
  fi
  echo 'export PATH=$PATH:$FABRIC_HOME/bin' >>~/.profile
  echo "FABRIC_HOME:" $FABRIC_HOME
  source ~/.profile
}
makeDirectories() {
  mkdir -p $FABRIC_CFG_PATH
  mkdir -p $FABRIC_HOME/channel-artifacts
}
installPlatformBinaries() {
  echo "===> Downloading platform binaries"
  which configtxgen
  if [ $? -eq 0 ]; then
    echo "############################# FABRIC Exists already ##################################################################"
  else
    cd $FABRIC_HOME || exit
    curl https://nexus.hyperledger.org/content/repositories/releases/org/hyperledger/fabric/hyperledger-fabric/${ARCH}-${VERSION}/hyperledger-fabric-${ARCH}-${VERSION}.tar.gz | tar xz
    echo "<=== Finished installing platform binaries"
  fi
}
#### To be used only if docker based install is desired.
dockerFabricPull() {
  local FABRIC_TAG=$1
  for IMAGES in peer orderer couchdb ccenv javaenv kafka zookeeper tools; do
    echo "==> FABRIC IMAGE: $IMAGES"
    echo
    docker pull hyperledger/fabric-$IMAGES:$FABRIC_TAG
    docker tag hyperledger/fabric-$IMAGES:$FABRIC_TAG hyperledger/fabric-$IMAGES
  done
}
generateConfigTx() {
  cd $FABRIC_HOME/channel-artifacts || exit
  rm -rf *
  echo "Number of files:"
  ls -l
  cd $FABRIC_HOME || exit
  rm *.log *.pid
  curl -o $FABRIC_HOME/config/configtx.yaml https://raw.githubusercontent.com/vijayraghavanv/FHCLContract/master/configtx.yaml
  curl -o $FABRIC_HOME/config/orderer.yaml https://raw.githubusercontent.com/vijayraghavanv/FHCLContract/master/orderer.yaml
  curl -o $FABRIC_HOME/config/core.yaml https://raw.githubusercontent.com/vijayraghavanv/FHCLContract/master/core.yaml
  cd $FABRIC_HOME/config || exit
  sed -i -e "s/ORGNAME/$primaryOrgName/gi; s/Supplier/$secondaryOrgName/gi; s/CHANNEL_PROFILE/$channelProfile/gi" "$FABRIC_HOME/config/configtx.yaml"
  sed -i -e "s/ORGNAME/$primaryOrgName/gi; s/Supplier/$secondaryOrgName/gi; s/0.0.0.0/$IP_ADDRESS/gi" "$FABRIC_HOME/config/orderer.yaml"
  if [[ $OrgChoice = 1 ]]; then
    sed -i -e "s/ORGNAME/$primaryOrgName/gi; s/0.0.0.0/$IP_ADDRESS/gi" "$FABRIC_HOME/config/core.yaml"
  else
    sed -i -e "s/ORGNAME/$secondaryOrgName/gi; s/0.0.0.0/$IP_ADDRESS/gi" "$FABRIC_HOME/config/core.yaml"
  fi
  if [ $OrgChoice = 1 ]; then
    configtxgen -profile Genesis -outputBlock $FABRIC_HOME/channel-artifacts/genesis.block
    echo "-------Created Genesis Block --------------"
    configtxgen -profile $channelProfile -outputCreateChannelTx $FABRIC_HOME/channel-artifacts/channel.tx -channelID $channelName
    echo "----------Created Channel transaction------"
    configtxgen -profile $channelProfile -outputAnchorPeersUpdate $FABRIC_HOME/channel-artifacts/${primaryOrgName}Anchors.tx -channelID $channelName -asOrg $primaryOrgName
    echo "----------Created Anchor Peer Update ------"
    orderer start > $FABRIC_HOME/orderer.log 2>&1 &
    sleep 10
    echo $! >$FABRIC_HOME/orderer.pid
    if [ $? -ne 0 ]; then
      echo "Failed to start orderer in $HOME"
      exit
    fi
    checkProcess orderer
    cd $FABRIC_HOME/channel-artifacts || exit
    peer channel create -o orderer.${primaryOrgName}:7050 -c $channelName -f $FABRIC_HOME/channel-artifacts/channel.tx
    echo "----------Created ${channelName}'s genesis block ------"
  else
    configtxgen -profile $channelProfile -outputAnchorPeersUpdate $FABRIC_HOME/channel-artifacts/${secondaryOrgName}Anchors.tx -channelID $channelName -asOrg $secondaryOrgName
    echo "----------Created Anchor Peer Update ------"
  fi
}
joinPeerToChannel() {
  if [ $OrgChoice = 1 ]; then
    peer node start > $FABRIC_HOME/peer.log 2>&1 &
    echo $! >$FABRIC_HOME/peer.pid
    if [ $? -ne 0 ]; then
      echo "Failed to start PEER"
    fi
    checkProcess peer
    peer channel join -b ${channelName}.block
  else
    cd $FABRIC_HOME/channel-artifacts || exit
    peer node start > $FABRIC_HOME/peer.log 2>&1 &
    peer channel fetch 0 $FABRIC_HOME/channel-artifacts/$channelName.block -o orderer.$primaryOrgName:7050 -c $channelName
    sleep 5
    peer channel join -b $channelName.block
  fi
}
function checkProcess() {
  PROCESS_NAME=$1
  pidFile=$FABRIC_HOME/${PROCESS_NAME}.pid
  if [ ! -f $pidFile ]; then
    fatal "No PID file for $PROCESS_NAME at"
  fi
  pid=$(cat $pidFile)
  if ps -p $pid >/dev/null; then
    echo  "$PROCESS_NAME server is started"
  else
    echo " $PROCESS_NAME server is not running "
    exit
  fi
}
#stopProcess arg1
#arg1: pass orderer or peer
function stopProcess {
  PROCESS_NAME=$1
  for pidFile in $(find $FABRIC_HOME -name $PROCESS_NAME.pid); do
    if [ ! -f $pidFile ]; then
      echo "\"$pidFile\" is not a file"
      exit
    fi
    pid=$(cat $pidFile)
    dir=$(dirname $pidFile)
    echo "Stopping Process in $dir with PID $pid ..."
    if ps -p $pid >/dev/null; then
      kill -9 $pid
      wait $pid 2>/dev/null
      rm -f $pidFile
      echo "Stopped Process in $dir with PID $pid"
    fi
  done
}
main() {
  addHosts
  setEnvVariables
  makeDirectories
  installPlatformBinaries
  if [ -d "$HOME/$secondaryOrgName" ]; then
    cp -r $HOME/$secondaryOrgName $HOME/cryptoconfig/peerOrganizations/
  else
    echo "Unable to find crypto material for second org. Exiting....."
    exit 1
  fi
  echo "#################################### Generating Config Transactions ####################################################"
  generateConfigTx
  joinPeerToChannel
  if [[ $OrgChoice = 1 ]]; then
    setupBlockChainNetworkonSecondOrg
  fi
  stopProcess orderer
  stopProcess peer
}
addHosts() {
  EXT_IP_ADDRESS=$(curl ifconfig.co)
  HOSTNAME=$(hostname -s)
  echo "adding host"
  HOSTS_LINE="$EXT_IP_ADDRESS\t$HOSTNAME"
  if [ -n "$(grep $HOSTNAME /etc/hosts)" ]; then
    echo "$HOSTNAME already exists : $(grep $HOSTNAME /etc/hosts)"
  else
    echo "Adding $HOSTNAME to your /etc/hosts"
    sudo -- sh -c -e "echo '$HOSTS_LINE' >> /etc/hosts"
    if [ -n "$(grep $HOSTNAME /etc/hosts)" ]; then
      echo "$HOSTNAME was added succesfully \n $(grep $HOSTNAME /etc/hosts)"
    else
      echo "Failed to Add $HOSTNAME, Try again!"
    fi
  fi
  if [[ $OrgChoice = 1 ]]; then
    ORDERER_IP=$EXT_IP_ADDRESS
  else
    ORDERER_IP=$primaryOrgIP
  fi
  if [ -n "$(grep orderer.$primaryOrgName /etc/hosts)" ]; then
    echo "orderer.$primaryOrgName already exists : $(grep orderer.$primaryOrgName /etc/hosts)"
  else
    echo "Adding orderer.$primaryOrgName to your /etc/hosts"
    ORDERER_LINE="$ORDERER_IP\torderer.${primaryOrgName}"
    sudo -- sh -c -e "echo '$ORDERER_LINE' >> /etc/hosts"
    if [ -n "$(grep orderer.$primaryOrgName /etc/hosts)" ]; then
      echo "orderer.$primaryOrgName was added succesfully \n $(grep orderer.$primaryOrgName /etc/hosts)"
    else
      echo "Failed to Add orderer.$primaryOrgName, Try again!"
    fi
  fi
  if [[ $OrgChoice = 1 ]]; then
    if [ -n "$(grep peer0.$primaryOrgName /etc/hosts)" ]; then
      echo "peer0.$primaryOrgName already exists : $(grep peer0.$primaryOrgName /etc/hosts)"
    else
      PEER0_LINE="$EXT_IP_ADDRESS\tpeer0.${primaryOrgName}"
      sudo -- sh -c -e "echo '$PEER0_LINE' >> /etc/hosts"
      if [ -n "$(grep peer0.$primaryOrgName /etc/hosts)" ]; then
        echo "peer0.$primaryOrgName was added succesfully \n $(grep peer0.$primaryOrgName /etc/hosts)"
      else
        echo "Failed to Add peer0.$primaryOrgName, Try again!"
      fi
    fi
    if [ -n "$(grep peer1.$primaryOrgName /etc/hosts)" ]; then
      echo "peer1.$primaryOrgName already exists : $(grep peer1.$primaryOrgName /etc/hosts)"
    else
      echo "Adding peer1.$primaryOrgName to your /etc/hosts"
      PEER1_LINE="$EXT_IP_ADDRESS\tpeer1.${primaryOrgName}"
      sudo -- sh -c -e "echo '$PEER1_LINE' >> /etc/hosts"
      if [ -n "$(grep peer1.$primaryOrgName /etc/hosts)" ]; then
        echo "peer1.$primaryOrgName was added succesfully \n $(grep peer1.$primaryOrgName /etc/hosts)"
      else
        echo "Failed to Add peer1.$primaryOrgName, Try again!"
      fi
    fi
  else
    if [ -n "$(grep peer.$secondaryOrgName /etc/hosts)" ]; then
      echo "peer.$secondaryOrgName already exists : $(grep peer.$secondaryOrgName /etc/hosts)"
    else
      PEER_LINE="$EXT_IP_ADDRESS\tpeer.${secondaryOrgName}"
      sudo -- sh -c -e "echo '$PEER_LINE' >> /etc/hosts"
      if [ -n "$(grep peer.$secondaryOrgName /etc/hosts)" ]; then
        echo "peer.$secondaryOrgName was added succesfully \n $(grep peer.$secondaryOrgName /etc/hosts)"
      else
        echo "Failed to Add peer.$secondaryOrgName, Try again!"
      fi
    fi
  fi
}
setupBlockChainNetworkonSecondOrg() {
  primaryOrgIP=$(curl ifconfig.co)
  ssh -i $HOME/VijayPrivate.pem ubuntu@cts "mkdir -p $HOME/scripts; chmod +777 $HOME/scripts/*"
  scp -i $HOME/VijayPrivate.pem $HOME/scripts/setupBlockChainNetwork.sh ubuntu@cts:/home/ubuntu/scripts
  ssh -i $HOME/VijayPrivate.pem ubuntu@cts "/home/ubuntu/scripts/setupBlockChainNetwork.sh $BCName $VERSION 2 $primaryOrgName $secondaryOrgName $channelName $channelProfile $primaryOrgIP> $HOME/install.log"
}
main
