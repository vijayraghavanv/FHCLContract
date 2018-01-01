#!/bin/bash
###########################################################################################################################
#################### Script to download the pre requisites. Use this script to setup two org blockchain ###################
#################### on two different servers. Doesnt use dockers. This script also installs ##############################
#################### fabric-ca server and generates MSPs.##################################################################
######## Usage: Run this script on the primary org and then on the secondary org. Copying secondary #######################
######## org's crypto to the primary org is done out of band. #############################################################
if [ $# -ne 5 ]; then
  echo "############################################Invalid number of arguments######################################################"
  echo "Usage:"
  echo "setupBlockChainBasics BlockChainName BlockchainVersion OrgChoice primaryOrgName secondaryOrgName privateKey"
  echo "e.g. setupBlockchainBasics myBC 1.1.0-preview 1 acme xyz"
  echo "BlockChainName: Name for this blockchain."
  echo "BlockChainVersion: Version for the blockchain that will be downloaded."
  echo "OrgChoice: This setup is for 2 organizations. Use 1 for primary and 2 for secondary"
  echo "primaryOrgName: The primary organization's name."
  echo "secondaryOrgName: The name of the second org that will particpate in this blockchain"
  echo "privateKey: The private key that will be used to log into org2 website. Pass any string if calling the script from org2"
  exit 1
fi
BCName=$1
BCVersion=$2
OrgChoice=$3
primaryOrgName=$4
secondaryOrgName=$5
if [ $3 = "1" ]; then
  ORGS="\
        orderer:$primaryOrgName:7054:1 \
        peer:$primaryOrgName:7056:2 \
        "
else
  ORGS="\
        peer:$secondaryOrgName:7054:1 \
        "
fi
echo "ORGS: $ORGS"
ETC_HOSTS=/etc/hosts
SERVER_IP=localhost
IP_ADDRESS=$(hostname -i)
EXT_IP_ADDRESS=$(curl ifconfig.co)
HOSTNAME=$(hostname -s)
# If true, recreate crypto if it already exists
RECREATE=true
FCAHOME=$GOPATH/src/github.com/hyperledger/fabric-ca
# Crypto-config directory
CDIR="$HOME/cryptoconfig"
# More verbose logging for fabric-ca-server & fabric-ca-client
DEBUG=-d
addHosts() {
  echo "adding host"
  HOSTS_LINE="$EXT_IP_ADDRESS\t$HOSTNAME"
  if [ -n "$(grep $EXT_IP_ADDRESS /etc/hosts)" ]; then
    echo "$EXT_IP_ADDRESS already exists : $(grep $EXT_IP_ADDRESS $ETC_HOSTS)"
  else
    echo "Adding $EXT_IP_ADDRESS to your $ETC_HOSTS"
    sudo -- sh -c -e "echo '$HOSTS_LINE' >> /etc/hosts"
    if [ -n "$(grep $EXT_IP_ADDRESS /etc/hosts)" ]; then
      echo "$EXT_IP_ADDRESS was added succesfully \n $(grep $EXT_IP_ADDRESS /etc/hosts)"
    else
      echo "Failed to Add $EXT_IP_ADDRESS, Try again!"
    fi
  fi
  if [ -n "$(grep orderer /etc/hosts)" ]; then
    echo "orderer.$primaryOrgName already exists : $(grep orderer.$primaryOrgName)"
  else
    echo "Adding orderer.$primaryOrgName to your $ETC_HOSTS"
    ORDERER_LINE="$EXT_IP_ADDRESS\torderer.${primaryOrgName}"
    sudo -- sh -c -e "echo '$ORDERER_LINE' >> /etc/hosts"
    if [ -n "$(grep orderer.$primaryOrgName /etc/hosts)" ]; then
      echo "orderer.$primaryOrgName was added succesfully \n $(grep orderer.$primaryOrgName /etc/hosts)"
    else
      echo "Failed to Add orderer.$primaryOrgName, Try again!"
    fi
  fi
}
generateMSP() {
  CLIENT=$GOPATH/bin/fabric-ca-client
  curl -o $FABRIC_CA_SERVER_HOME/fabric-ca-server-config.yaml https://raw.githubusercontent.com/vijayraghavanv/FHCLContract/master/fabric-ca-server-config.yaml
  if [ $OrgChoice = "1" ]; then
    sed -i -e "s/orgName/$primaryOrgName/gi; s/organizationHostName/$HOSTNAME/gi" "$FABRIC_CA_SERVER_HOME/fabric-ca-server-config.yaml"
  else
    sed -i -e "s/orgName/$secondaryOrgName/gi; s/organizationHostName/$HOSTNAME/gi" "$FABRIC_CA_SERVER_HOME/fabric-ca-server-config.yaml"
  fi
  if [[ -d $CDIR && "$RECREATE" == false ]]; then
    echo "#################################################################"
    echo "#######    Crypto material already exists   #####################"
    echo "#################################################################"
    exit 0
  fi
  mkdir $CDIR
  cd $FABRIC_CA_SERVER_HOME || exit
  rm -rf *
  cd $CDIR || exit
  rm -rf *
  echo "#################################################################"
  echo "#######    Generating crypto material using Fabric CA  ##########"
  echo "#################################################################"
  mydir=$(pwd)
  cd $mydir || exit
  curl -o $FABRIC_CA_CFG_PATH/fabric-ca-client-config.yaml https://raw.githubusercontent.com/vijayraghavanv/FHCLContract/master/fabric-ca-client-config.yaml
  if [ $OrgChoice = "1" ]; then
    name1="- $primaryOrgName"
    name2="    - orderer.$primaryOrgName"
    name3="    - peer0.$primaryOrgName"
    name4="    - peer1.$primaryOrgName"
    name5="    - $HOSTNAME"
    name6="$name1"$'\n'"$name2"$'\n'"$name3"$'\n'"$name4"$'\n'"$name5"
  else
    name1="- $secondaryOrgName"
    name2="    - peer.$secondaryOrgName"
    name3="    - $HOSTNAME"
    name6="$name1"$'\n'"$name2"$'\n'"$name3"
  fi
  echo "Replaced Name is: $name6"
  sed -i -e "s/orgName/$primaryOrgName/gi; s/- orgHostName/${name6//$'\n'/\\n}/gi;" "$FABRIC_CA_CFG_PATH/fabric-ca-client-config.yaml"
  echo "Setting up organizations ..."
  setupOrgs
  echo "Finishing ..."
  stopAllCAs
  echo "Complete"
}
setupOrgs() {
  for ORG in $ORGS; do
    setupOrg $ORG
  done
}
#   setupOrg <type>:<orgName>:<rootCAPort>:<numNodes>
setupOrg() {
  IFSBU=$IFS
  echo IFSBU : $IFS
  echo $IFSBU
  IFS=: args=($1)
  # if number of args is not equal to 4 exit
  if [ ${#args[@]} -ne 4 ]; then
    fatal "setupOrg: bad org spec: $1"
  fi
  type=${args[0]}
  orgName=${args[1]}
  echo ORG NAME IS: $orgName
  orgDir=${CDIR}/${type}Organizations/${args[1]}
  echo org dir is: $orgDir
  rootCAPort=${args[2]}
  numNodes=${args[3]}
  IFS=$IFSBU
  #Start the root server
  startCA $orgDir/ca/root $rootCAPort $orgName
  # Enroll an admin user with the root CA
  usersDir=$orgDir/users
  adminHome=$usersDir/rootAdmin
  #Create bootstrap admin for the client
  enroll $adminHome http://admin:adminpw@$SERVER_IP:$rootCAPort $orgName
  adminUserHome=$usersDir/Admin@${orgName}
  registerAndEnroll $adminHome $adminUserHome $rootCAPort $orgName nodeAdmin
  # Register and enroll user1 with the intermediate CA
  user1UserHome=$usersDir/User1@${orgName}
  registerAndEnroll $adminHome $user1UserHome $rootCAPort $orgName
  # Create nodes (orderers or peers)
  nodeCount=0
  while [ $nodeCount -lt $numNodes ]; do
    if [ $numNodes -gt 1 ]; then
      nodeDir=$orgDir/${type}s/${type}${nodeCount}.${orgName}
    else
      nodeDir=$orgDir/${type}s/${type}.${orgName}
    fi
    mkdir -p $nodeDir
    # Get TLS crypto for this node
    tlsEnroll $nodeDir $rootCAPort $orgName
    # Register and enroll this node's identity
    registerAndEnroll $adminHome $nodeDir $rootCAPort $orgName
    normalizeMSP $nodeDir $orgName $adminUserHome
    nodeCount=$(expr $nodeCount + 1)
  done
  # Get CA certs from intermediate CA
  serverURL=http://admin:adminpw@$SERVER_IP:$rootCAPort
  getcacerts $orgDir $serverURL
  # Rename MSP files to names expected by end-to-end
  normalizeMSP $orgDir $orgName $adminUserHome
  normalizeMSP $adminHome $orgName
  normalizeMSP $adminUserHome $orgName
  normalizeMSP $user1UserHome $orgName
}
# Register a new user
#    register <user> <password> <registrarHomeDir> <url>
function register() {
  export FABRIC_CA_CLIENT_HOME=$3
  mkdir -p $3
  cp $FABRIC_CA_CFG_PATH/fabric-ca-client-config.yaml $FABRIC_CA_CLIENT_HOME
  logFile=$3/register.log
  $CLIENT register --id.name $1 --id.secret $2 --id.type user --id.affiliation org1 $DEBUG -u $4 >$logFile 2>&1
  if [ $? -ne 0 ]; then
    debug "Failed to register $1 with CA as $3; see $logFile"
  fi
  debug "Registered user $1 with intermediate CA as $3"
}

# Enroll an identity
#    enroll <homeDir> <serverURL> <orgName> [<args>]
enroll() {
  homeDir=$1
  shift
  url=$1
  shift
  orgName=$1
  shift
  mkdir -p $homeDir
  export FABRIC_CA_CLIENT_HOME=$homeDir
  cp $FABRIC_CA_CFG_PATH/fabric-ca-client-config.yaml $FABRIC_CA_CLIENT_HOME
  logFile=$homeDir/enroll.log
  # Get an enrollment certificate
  $CLIENT enroll -u $url $DEBUG >$logFile 2>&1
  if [ $? -ne 0 ]; then
    fatal "Failed to enroll $homeDir with CA at $url; see $logFile"
  fi
  # Get a TLS certificate
  debug "Enrolled $homeDir with CA at $url"
}

# Register and enroll a new user
#    registerAndEnroll <registrarHomeDir> <registreeHomeDir> <serverPort> <orgName> [<userName>]
registerAndEnroll() {
  userName=$5
  if [ "$userName" = "" ]; then
    userName=$(basename $2)
  fi
  #Uses default password as secret for registering and enrolling all users
  register $userName "secret" $1 $SERVER_IP:$3
  enroll $2 http://${userName}:secret@$SERVER_IP:$3 $4
}

# Enroll to get TLS crypto material
#    tlsEnroll <homeDir> <serverPort> <orgName>
#orgDir/ca/root 7054 supplier.com
tlsEnroll() {
  homeDir=$1
  port=$2
  orgName=$3
  host=$(basename $homeDir),$(basename $homeDir | cut -d'.' -f1)
  echo csr.hosts:$host
  tlsDir=$homeDir/tls
  srcMSP=$tlsDir/msp
  dstMSP=$homeDir/msp
  enroll $tlsDir http://admin:adminpw@$SERVER_IP:$port $orgName --csr.hosts $host --enrollment.profile tls
  cp $srcMSP/signcerts/* $tlsDir/server.crt
  cp $srcMSP/keystore/* $tlsDir/server.key
  mkdir -p $dstMSP/keystore
  cp $srcMSP/keystore/* $dstMSP/keystore
  mkdir -p $dstMSP/tlscacerts
  cp $srcMSP/tlscacerts/* $dstMSP/tlscacerts/tlsca.${orgName}-cert.pem
  if [ -d $srcMSP/tlsintermediatecerts ]; then
    cp $srcMSP/tlsintermediatecerts/* $tlsDir/ca.crt
    mkdir -p $dstMSP/tlsintermediatecerts
    cp $srcMSP/tlsintermediatecerts/* $dstMSP/tlsintermediatecerts
  else
    cp $srcMSP/tlscacerts/* $tlsDir/ca.crt
  fi
  rm -rf $srcMSP $homeDir/enroll.log $homeDir/fabric-ca-client-config.yaml
}

# Rename MSP files as is expected by the e2e example
#    normalizeMSP <home> <orgName> <adminHome>
normalizeMSP() {
  userName=$(basename $1)
  mspDir=$1/msp
  orgName=$2
  admincerts=$mspDir/admincerts
  cacerts=$mspDir/cacerts
  intcerts=$mspDir/intermediatecerts
  signcerts=$mspDir/signcerts
  cacertsfname=$cacerts/ca.${orgName}-cert.pem
  if [ ! -f $cacertsfname ]; then
    mv $cacerts/* $cacertsfname
  fi
  intcertsfname=$intcerts/ca.${orgName}-cert.pem
  if [ ! -f $intcertsfname ]; then
    if [ -d $intcerts ]; then
      mv $intcerts/* $intcertsfname
    fi
  fi
  signcertsfname=$signcerts/${userName}-cert.pem
  if [ ! -f $signcertsfname ]; then
    fname=$(ls $signcerts 2>/dev/null)
    if [ "$fname" = "" ]; then
      mkdir -p $signcerts
      cp $cacertsfname $signcertsfname
    else
      mv $signcerts/* $signcertsfname
    fi
  fi
  # Copy the admin cert, which would need to be done out-of-band in the real world
  mkdir -p $admincerts
  if [ $# -gt 2 ]; then
    src=$(ls $3/msp/signcerts/*)
    dst=$admincerts/Admin@${orgName}-cert.pem
  else
    src=$(ls $signcerts/*)
    dst=$admincerts
  fi
  if [ ! -f $src ]; then
    fatal "admin certificate file not found at $src"
  fi
  cp $src $dst
}
# Get the CA certificates and place in MSP directory in <dir>
#    getcacerts <dir> <serverURL>
getcacerts() {
  mkdir -p $1
  export FABRIC_CA_CLIENT_HOME=$1
  $CLIENT getcacert -u $2 >$1/getcacert.out 2>&1
  if [ $? -ne 0 ]; then
    fatal "Failed to get CA certificates $1 with CA at $2; see $logFile"
  fi
  mkdir $1/msp/tlscacerts
  cp $1/msp/cacerts/* $1/msp/tlscacerts
  debug "Loaded CA certificates into $1 from CA at $2"
}

# Print a fatal error message and exit
fatal() {
  echo "FATAL: $*"
  exit 1
}

# Print a debug message
debug() {
  echo "    $*"
}
# Start a root CA server:
#    startCA <homeDirectory> <listeningPort> <orgName>
# Start an intermediate CA server:
#    startCA <homeDirectory> <listeningPort> <orgName> <parentURL>
startCA() {
  homeDir=$1
  shift
  port=$1
  shift
  orgName=$1
  shift
  mkdir -p $homeDir
  SERVER=$GOPATH/bin/fabric-ca-server
  #   export FABRIC_CA_SERVER_HOME=$homeDir
  if [ $# -gt 0 ]; then
    $SERVER start -p $port -b admin:adminpw -u $1 $DEBUG >$FABRIC_CA_SERVER_HOME/server.log 2>&1 &
  else
    $SERVER start -p $port -b admin:adminpw $DEBUG >$FABRIC_CA_SERVER_HOME/server.log 2>&1 &
  fi
  echo $! >$homeDir/server.pid
  if [ $? -ne 0 ]; then
    fatal "Failed to start server in $homeDir"
  fi
  debug "Starting CA server in $homeDir on port $port ...."
  sleep 1
  checkCA $homeDir $port
  tlsEnroll $homeDir $port $orgName
}
function checkCA() {
  pidFile=$1/server.pid
  if [ ! -f $pidFile ]; then
    fatal "No PID file for CA server at $1"
  fi
  pid=$(cat $pidFile)
  if ps -p $pid >/dev/null; then
    debug "CA server is started in $1 and listening on port $2"
  else
    fatal "CA server is not running at $1; see logs at $1/server.log"
  fi
}
function stopAllCAs() {
  for pidFile in $(find $CDIR -name server.pid); do
    if [ ! -f $pidFile ]; then
      fatal "\"$pidFile\" is not a file"
    fi
    pid=$(cat $pidFile)
    dir=$(dirname $pidFile)
    debug "Stopping CA server in $dir with PID $pid ..."
    if ps -p $pid >/dev/null; then
      kill -9 $pid
      wait $pid 2>/dev/null
      rm -f $pidFile
      debug "Stopped CA server in $dir with PID $pid"
    fi
  done
}
installDocker() {
  echo ##########################################################################
  echo
  echo "#######################################################Installing docker .....#######################################################"
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
  sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu/ $(lsb_release -cs) stable"
  sudo apt-get update
  sudo apt-get install docker-ce
  sudo usermod -aG docker $USER
  echo "###################################################Finished installing docker########################################################"
  echo "Installing docker compose. Change the version number to the latest docker-compose version"
  sudo curl -L https://github.com/docker/compose/releases/download/1.17.0/docker-compose-Linux-x86_64 -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
}
#Install Go
installGo() {
  echo "Installing go version 1.9.2...."
  wget -c https://storage.googleapis.com/golang/go1.9.2.linux-amd64.tar.gz
  sudo tar -xvf go1.9.2.linux-amd64.tar.gz
  sudo mv go /usr/local
  mkdir -p $HOME/fabric/go
  echo "Finsihed installing go 1.9.2"
}

#Install Node.js
installnodeJS() {
  echo "Installing Node.js. Latest 6.x version needs to be installed as 7.x is not supported"
  curl -sL https://deb.nodesource.com/setup_6.x | sudo -E bash -
  sudo apt-get install -y nodejs
  sudo npm install npm@3.10.10 -g
  echo "Python version is: " python -version
}
setEnvVariables() {
  #shellcheck source=/home/.profile
  source ~/.profile
  if [[ ! ${GOPATH+x} ]]; then
    echo 'export GOPATH=$HOME/fabric/go' >>~/.profile
    GOPATH=$HOME/fabric/go
  fi
  if [[ ! ${FABRIC_CA_SERVER_HOME+x} ]]; then
    echo 'export FABRIC_CA_SERVER_HOME=$HOME/fabric-ca/server' >>~/.profile
    FABRIC_CA_SERVER_HOME=$HOME/fabric-ca/server
  fi
  if [[ ! ${FABRIC_CA_CLIENT_HOME+x} ]]; then
    echo 'export FABRIC_CA_CLIENT_HOME=$HOME/fabric-ca/client' >>~/.profile
    FABRIC_CA_CLIENT_HOME=$HOME/fabric-ca/client
  fi
  if [[ ! ${CA_CFG_PATH+x} ]]; then
    echo 'export CA_CFG_PATH=$HOME/fabric-ca' >>~/.profile
    CA_CFG_PATH=$HOME/fabric-ca
  fi
  if [[ ! ${FABRIC_CA_ROOT+x} ]]; then
    echo 'export FABRIC_CA_ROOT=$GOPATH/src/github.com/hyperledger/fabric-ca' >>~/.profile
    FABRIC_CA_ROOT=$GOPATH/src/github.com/hyperledger/fabric-ca
  fi
  if [[ ! ${FABRIC_CA_HOME+x} ]]; then
    echo 'export FABRIC_CA_HOME=$HOME/fabric-ca' >>~/.profile
    FABRIC_CA_HOME=$HOME/fabric-ca
  fi
  if [[ ! ${FABRIC_CA_CFG_PATH+x} ]]; then
    echo 'export FABRIC_CA_CFG_PATH=$HOME/fabric-ca/client' >>~/.profile
    FABRIC_CA_CFG_PATH=$HOME/fabric-ca/client
  fi
  echo 'export PATH=$PATH:$GOPATH/bin' >>~/.profile
  echo 'export PATH=$FABRIC_CA_ROOT/bin:$PATH' >>~/.profile
  echo 'export PATH=$PATH:/usr/local/go/bin' >>~/.profile
  PATH=$PATH:$GOPATH/bin:$FABRIC_CA_ROOT/bin:/usr/local/go/bin
  #shellcheck source=/home/.profile
  source ~/.profile
  echo "GOPATH after setting is: $GOPATH"
  echo "PATH is : $PATH"
  echo $(which fabric-ca-server)
}
makeDirectories() {
  mkdir -p $GOPATH $FABRIC_CA_ROOT $FABRIC_CA_HOME $CA_CFG_PATH $FABRIC_CA_SERVER_HOME $FABRIC_CA_CLIENT_HOME
}
main() {
  echo "###########################################  Installing Pre reqisites #####################################################"
  installPreReqs
  echo "##                                                                                                                       ##"
  echo "##                                                                                                                       ##"
  echo "##                                                                                                                       ##"
  echo "##                                                                                                                       ##"
  echo "##                                                                                                                       ##"
  echo "#####################################  Finsihed Installing Pre reqisites ##################################################"
  echo "####################################### Setting Environment Variables #####################################################"
  setEnvVariables
  source ~/.profile
  echo "##                                                                                                                       ##"
  echo "##                                                                                                                       ##"
  echo "##                                                                                                                       ##"
  echo "##                                                                                                                       ##"
  echo "##                                                                                                                       ##"
  echo "################################  Finsihed Setting environment variables ##################################################"
  makeDirectories
  echo "####################################### Installing Fabric CA  #############################################################"
  installFabric
  echo "##                                                                                                                       ##"
  echo "##                                                                                                                       ##"
  echo "##                                                                                                                       ##"
  echo "##                                                                                                                       ##"
  echo "##                                                                                                                       ##"
  echo "################################  Finsihed Installing Fabric CA ###########################################################"
  echo "####################################### Generating MSP ###### #############################################################"
  generateMSP
  echo "##                                                                                                                       ##"
  echo "##                                                                                                                       ##"
  echo "##                                                                                                                       ##"
  echo "##                                                                                                                       ##"
  echo "##                                                                                                                       ##"
  echo "################################  Finsihed Generating MSP ###########################################################"
  addHosts
  if [ $OrgChoice != "1" ]; then
    createMSPDirWithoutKeystore
  fi
}
createMSPDirWithoutKeystore() {
  cd $CDIR/peerOrganizations || exit
  mkdir -p /home/ubuntu/cryptotransfer
  cp -r * /home/ubuntu/cryptotransfer
  cd /home/ubuntu/cryptotransfer
  find -type d -name keystore -exec rm -rf {} \;
}

installFabric() {
  which fabric-ca-server
  if [ $? -eq 0 ]; then
    echo "############################# FABRIC CA Exists already ##################################################################"
  else
    sudo rm -rf /var/cache/apt
    echo "##########################################. Downloading FABRIC_CA files. ##################################################"
    cd $GOPATH/src/github.com/hyperledger/ || exit
    rm -rf *
    echo "############################################Completed Downloading Fabric CA ###############################################"
    wget https://github.com/hyperledger/fabric-ca/archive/v$BCVersion.zip
    unzip v$BCVersion.zip
    rm v$BCVersion.zip
    mv fabric-ca-$BCVersion/ fabric-ca/
    go install -ldflags "-X github.com/hyperledger/fabric-ca/cmd.Version=$BCVersion" github.com/hyperledger/fabric-ca/cmd/...
    sudo cp $FABRIC_CA_ROOT/images/fabric-ca/payload/*.pem $FABRIC_CA_HOME
  fi
}
#Install all pre-requisites that are common for Fabric-ca server, client,orderer and peer.
installPreReqs() {
  sudo apt-get update
  sudo apt-get upgrade -y
  sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
  which docker
  if [ $? -eq 0 ]; then
    echo "############################## Docker Exists - Skipping Installation ###################################################"
  else
    echo "Skipping docker install and using direct installs. Uncomment the following line to use docker"
    #installDocker
  fi
  which go
  if [ $? -eq 0 ]; then
    echo "############################### GO already installed ##################################################################"
  else
    installGo
  fi
  which nodejs
  if [ $? -eq 0 ]; then
    echo "############################### NodeJS already installed ##################################################################"
  else
    installnodeJS
  fi
  sudo apt-get install -y libtool unzip libltdl-dev
}
main
