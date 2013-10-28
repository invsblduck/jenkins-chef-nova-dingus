#!/bin/bash

set -u
set -e
set -x

PLATFORM=debian
COOKBOOK_PATH=/root
COOKBOOK_OVERRIDE=""

if [ -e /etc/redhat-release ]; then
    if [[ $(grep -c "CentOS" /etc/redhat-release) ]]; then
        PLATFORM=centos
    else
        PLATFORM=redhat
    fi
else
    PLATFORM=debian
fi

function run_twice() {
    local cmd_to_run="$@"
    if ! $cmd_to_run; then
        # try it again!
        sleep 10
        $cmd_to_run
    fi
}

function unmount_filesystem() {
    if [[ -z $1 ]]; then
        echo "no mount point specified"
    else
        if $(mountpoint -q $1); then
            umount $1
        else
           echo "unmount_filesystem: $1 is not mounted"
        fi
    fi
}

function fixup_log_files_for_fetch() {
    # copy interesting files/directories to /tmp/logfilecopy so we can
    # grab it from the jenkins job and post it as an artifact
    OLD_IFS=${IFS}
    IFS=","
    mkdir -p /tmp/logfilecopy
    for d in ${JOB_ARCHIVE_FILES[@]}; do
      # ignore failures on the copy
      cp -dR --parents --strip-trailing-slashes ${d} /tmp/logfilecopy/ || :
    done;
    IFS=${OLD_IFS}
    # fix up the permissions so we can copy it as an unprivileged used
    find /tmp/logfilecopy -type d -exec chmod 777 \{\} \;
    find /tmp/logfilecopy -type f -exec chmod 666 \{\} \;
    # grab the list of running processes as well
    pstree > /tmp/logfilecopy/running-processes.txt
    echo "" >> /tmp/logfilecopy/running-processes.txt
    echo "" >> /tmp/logfilecopy/running-processes.txt
    ps auxwww >> /tmp/logfilecopy/running-processes.txt
    if [ ${PLATFORM} = "debian" ]; then
        dpkg -l > /tmp/logfilecopy/installed-packages.txt
    else
        rpm -qa > /tmp/logfilecopy/installed-packages.txt
    fi
}

function prep_chef_client() {
    chef-client -o 'role[base],recipe[build-essential]'
}

function make_roush_log_dev_null() {
    sed -i 's/^logfile=.*/logfile=\/dev\/null/g' /etc/roush/roush.conf
}

function add_repo_key() {
    # $1 - repo
    #
    # The actual key might vary based on repo, this should be factored out
    # if we need to at some point
    #
    if [ ${PLATFORM} = "debian" ]; then
        apt-key adv --keyserver hkp://subkeys.pgp.net --recv-keys 765C5E49F87CBDE0
    else
        echo "add_repo_key not implemented for non-debian"
        exit 1
    fi
}


function wait_for_rhn() {
    local max_tries=20
    local tries=0

    if [ $PLATFORM = "debian" ]; then
        echo "rhn check not supported on debian"
    elif [ ! -x /usr/sbin/rhn_check ]; then
        echo "rhn not installed on this system"
    else
        while ! /usr/sbin/rhn_check 2>&1>/dev/null; do
            if [[ ${tries} == ${max_tries} ]]; then
                echo "rhn did not become active in ${tries} tries"
                exit 1
            else
                sleep 5s
                tries=$(( $tries + 1 ))
            fi
        done
        echo "rhn active.  errors above this may not be important"
    fi
}

function plumb_quantum_networks() {
    local interface_name=$1
    if [ ${PLATFORM} = "debian" ]; then
        cat >> /etc/network/interfaces <<EOF
auto ${interface_name}
iface ${interface_name} inet dhcp
EOF
    else
        cat >> /etc/sysconfig/network-scripts/ifcfg-${interface_name} <<EOF
DEVICE="${interface_name}"
ONBOOT="yes"
BOOTPROTO="dhcp"
IPV6INIT="no"
MTU="1500"
NM_CONTROLLED="no"
EOF
    fi
    ifup ${interface_name}
}

function fixup_hosts_file_for_quantum() {
    echo "$(ip a show dev eth0 | grep "inet.*eth0" | awk '{print $2}' | cut -d '/' -f 1) $(hostname).novalocal $(hostname)" >> /etc/hosts
}

function set_quantum_network_link_up() {
    local interface_name=$1
    ip l s dev ${interface_name} up || :
}

function cleanup_metadata_routes() {
    # remove the metadata route from eth0 after we've got the instance up
    for eth_dev in "$@"; do
      ip r d 169.254.169.254 dev $eth_dev || :
    done
}

function move_ip_to_ovs_bridge() {
    physdev=$1
    bridgedev="br-${physdev}"
    IP=$(ip a show dev $physdev | grep "inet " | awk '{print $2}')
    ifdown $physdev >/dev/null 2>&1
    ip l s $physdev up
    ovs-vsctl add-br $bridgedev
    ovs-vsctl add-port $bridgedev $physdev
    ip l s $bridgedev up
    ip a a ${IP} dev $bridgedev
}



function add_repo() {
    # $1 repo description

    local repo_file=/etc/apt/sources.list.d/${1}.list
    local repo_contents="deb http://build.monkeypuppetlabs.com/proposed-packages/rcb-utils precise rcb-utils"
    if [ ${PLATFORM} = "debian" ]; then
        if [ $1 == "proposed" ]; then
            echo "${repo_contents}" > ${repo_file}
        fi
    else
        # This does not work on Fedora - but we don't care right now
        if [ $1 == "proposed" ]; then
            cat > /etc/yum.repos.d/rcb <<EOF
[rcb-testing]
name=RCB Ops Testing Repo
baseurl=http://build.monkeypuppetlabs.com/repo-testing/RedHat/6/x86_64
gpgcheck=1
gpgkey=http://build.monkeypuppetlabs.com/repo/RPM-GPG-RCB.key
enabled=1
EOF
        fi
    fi
}

function set_package_provider() {
    if [ $PLATFORM = "debian" ]; then
        echo "Acquire { Retries \"5\"; HTTP { Proxy \"${JENKINS_PROXY}\"; }; };" >> /etc/apt/apt.conf
    elif [ $PLATFORM = "centos" ]; then
        # whack the cron jobs so they don't start on system boot
        chmod 000 /etc/cron.{d,daily,monthly,hourly,monthly}/*
        # going nuclear here
        rm -rf /var/cache/yum
#        sed -i '/^mirrorlist.*/d' /etc/yum.repos.d/CentOS-Base.repo
#        sed -i 's/^#baseurl/baseurl/g' /etc/yum.repos.d/CentOS-Base.repo
#        sed -i 's/mirror.centos.org\/centos/mirror.rackspace.com\/CentOS/g' /etc/yum.repos.d/CentOS-Base.repo
#        sed -i '/^mirrorlist.*/d' /etc/yum.repos.d/epel.repo
#        sed -i 's/^#baseurl/baseurl/g' /etc/yum.repos.d/epel.repo
#        sed -i 's/download.fedoraproject.org\/pub/mirror.rackspace.com/g' /etc/yum.repos.d/epel.repo
#        sed -i '/^mirrorlist.*/d' /etc/yum.repos.d/epel-testing.repo
#        sed -i 's/^#baseurl/baseurl/g' /etc/yum.repos.d/epel-testing.repo
#        sed -i 's/download.fedoraproject.org\/pub/mirror.rackspace.com/g' /etc/yum.repos.d/epel-testing.repo
#        echo "include_only=.edu,.gov" >> /etc/yum/pluginconf.d/fastestmirror.conf
        echo "exclude=.iu.edu, .arsc.edu" >> /etc/yum/pluginconf.d/fastestmirror.conf
        echo "proxy=${JENKINS_PROXY}" >> /etc/yum.conf
        yum makecache
    fi
    echo "proxy=${JENKINS_PROXY}" >> /root/.curlrc
    echo "http_proxy = ${JENKINS_PROXY}" >> /root/.wgetrc
    echo "use_proxy = on" >> /root/.wgetrc
}

function update_package_provider() {
    if [ $PLATFORM = "debian" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get update
    elif [ $PLATFORM = "centos" ]; then
        echo "skipping on non-debian systems"
    fi
}

function install_ovs_package() {
    if [ $PLATFORM = "debian" ]; then
        install_package linux-headers-$(uname -r)
        install_package openvswitch-datapath-lts-raring-dkms
        install_package openvswitch-switch
    else
        install_package openvswitch
    fi
}

function install_package() {
    if [ $PLATFORM = "debian" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y --force-yes "$@"
    else
        yum -y install "$@"
    fi
}

function start_ovs_service() {
    # we have to make sure the ovs service starts, because otherwise
    # ovs-vsctl will hang infinitely waiting for the socket (newer versions
    # of the client use a timeout by default).
    #
    script=/etc/init.d/openvswitch
    [ $PLATFORM = "debian" ] && script=${script}-switch

    if $script status |grep -qw 'not running'; then
        $script start
    fi
}

function start_chef_services() {
    /etc/init.d/chef-expander start
    /etc/init.d/chef-server-webui start
    /etc/init.d/chef-solr start
    /etc/init.d/rabbitmq-server start
    /etc/init.d/chef-server start
}

function rabbitmq_fixup() {
    local amqp_password=$(egrep "^amqp_pass" /etc/chef/server.rb | awk '{ print $2 }' | tr -d '"')

    # sometimes rabbit gets mad about hostnames changing
    # when booting from a snapshotted instance...
    /etc/init.d/rabbitmq-server stop || :
    pkill beam.smp || :
    /etc/init.d/rabbitmq-server start
    sleep 5

    if (! rabbitmqctl list_vhosts | grep -q chef ); then
        run_twice rabbitmqctl add_vhost /chef
        rabbitmqctl add_user chef ${amqp_password}
        rabbitmqctl set_permissions -p /chef chef ".*" ".*" ".*"
    fi
}

function ubuntu_fixups() {
    if [ $PLATFORM = "debian" ] || [ $PLATFORM = "ubuntu" ]; then
        # make sure we have the latest liblockfile.
        # see https://bugs.launchpad.net/ubuntu/+source/liblockfile/+bug/941968
        install_package liblockfile1
    fi
}

function chef11_fixup() {
    sed -i 's/chef-server/'$(hostname)'.novalocal/g' /etc/chef-server/chef-server.rb
    chef-server-ctl reconfigure
}

function chef_fixup() {
    cat > ${HOME}/.chef/knife.rb <<EOF
log_level                :info
log_location             STDOUT
node_name                'chefadmin'
client_key               '${HOME}/.chef/chefadmin.pem'
validation_client_name   'chef-validator'
validation_key           '${HOME}/.chef/validation.pem'
chef_server_url          'http://localhost:4000'
cache_type               'BasicFile'
cache_options( :path => '${HOME}/.chef/checksums' )
EOF

    # This is totally dangerously stupid
    mkdir -p /etc/chef
    cp /etc/chef/validation.pem /usr/share/chef-server-api/public
    cp ${HOME}/.chef/chefadmin.pem /usr/share/chef-server-api/public
    chmod 644 /usr/share/chef-server-api/public/chefadmin.pem
    chmod 644 /usr/share/chef-server-api/public/validation.pem
}


function checkout_cookbooks() {
    declare -a overrides
    local override

    GIT_MASTER_URL=${GIT_MASTER_URL:-https://github.com/rcbops/chef-cookbooks,master}

    mkdir -p ${COOKBOOK_PATH}
    cd ${COOKBOOK_PATH}

    local master_url=${GIT_MASTER_URL//,/ }
    declare -a master_info=(${master_url})
    local master_repo=${master_info[0]}
    local master_branch=${master_info[1]:-master}


    if [[ ${GIT_MASTER_URL} =~ "https://github.com/rcbops/chef-cookbooks" ]]; then
        echo "using the cached repo"
    else
        echo " we are looking at a different repo, so we can't use the one we have cached"
        rm -rf /root/chef-cookbooks
    fi

    if [[ -d /${COOKBOOK_PATH}/chef-cookbooks ]]; then
        cd chef-cookbooks
        git fetch origin
        git checkout ${master_branch}
        git clean -ffdx
        git pull origin ${master_branch}
        git submodule init
        git submodule sync
    else
        git clone ${master_repo}

        mkdir -p chef-cookbooks
        cd chef-cookbooks
        git checkout ${master_branch}
        git submodule init
    fi

    # github, y u no work?
    local count=1

    while [ $count -lt 10 ] && ! git submodule update; do
        sleep 10
        count=$((count + 1))
    done

    if [ $count -ge 10 ]; then
        # submodule update failed...
        echo "your github is b0rken"
        return 1
    fi

    pushd cookbooks
    # Okay, now start going through the overrides
    overrides=(${COOKBOOK_OVERRIDE-})
    if [ ! -z "${overrides:-}" ]; then
        for override in ${overrides[@]}; do
            echo "Doing override: ${override}"
            declare -a repo_info
            repo_info=(${override//,/ })
            local repo=${repo_info[0]}
            local branch=${repo_info[1]:-master}
            local dirname=$(echo ${repo##*/}|cut -d'.' -f1)

            if [ -e ${dirname} ]; then
                rm -rf ${dirname}
            fi

            git clone ${repo}
            pushd ${dirname}
            git checkout ${branch}
            popd
        done
    fi

    # If the overrides are specified as a git patch,
    # apply that patch, too
    if [ "${GIT_DIFF_URL:-}" != "" ]; then
        if [ "${GIT_REPO:-}" != "" ]; then
            cd ${GIT_REPO}
            curl -s ${GIT_DIFF_URL} | git apply -v --whitespace=fix
        fi
    fi
    popd
}

function upload_cookbooks() {
    cd ${COOKBOOK_PATH}/chef-cookbooks

    knife cookbook upload -o cookbooks -a
}

function upload_roles() {
    local whatdir=${1:-${COOKBOOK_PATH}/chef-cookbooks/roles}

    cd ${whatdir}
    knife role from file *.rb
}

function install_chef_client() {
    local extra_packages

    case $PLATFORM in
        debian|ubuntu)
            extra_packages="wget curl build-essential automake cgroup-lite"
            ;;
        redhat|fedora|centos|scientific)
            extra_packages="wget tar"
            ;;
    esac

    install_package ${extra_packages}

    if [ $PLATFORM = "debian" ] || [ $PLATFORM = "ubuntu" ]; then
        /usr/bin/cgroups-mount  # ?
    fi

    BASH_EXTRA_ARGS=""
    if [[ ${CHEF_CLIENT_VERSION} != "LATEST" ]]; then
        BASH_EXTRA_ARGS="-s - -v ${CHEF_CLIENT_VERSION}"
    fi
    echo "grabbing chef-client with arguments \"${BASH_EXTRA_ARGS}\""
    curl -skS http://www.opscode.com/chef/install.sh | /bin/bash ${BASH_EXTRA_ARGS} &
    wait $!
}

function swap_apt_source() {
    # $1 - new mirror (not mirror.rackspace.com)
    #
    sed -i /etc/apt/sources.list -e "s/mirror.rackspace.com/${1}/g"
}

function chef11_fetch_validation_pem() {
    # $1 - IP of chef server
    local ip=$1
    mkdir -p /etc/chef
    rm -f /etc/chef/validation.pem
    wget -nv --no-proxy http://${ip}:4000/docs/chef-validator.pem -O /etc/chef/validation.pem
}

function fetch_validation_pem() {
    # $1 - IP of chef server
    local ip=$1
    mkdir -p /etc/chef
    rm -f /etc/chef/validation.pem
    wget -nv --no-proxy http://${ip}:4000/validation.pem -O /etc/chef/validation.pem
}

function copy_file() {
    # $1 - file name
    # $2 - local path
    local file=$1
    local path=$2

    mkdir -p $(dirname ${path})
    cp /tmp/fakeconfig/${file} ${path}
}

function gretap_to_host() {
    # $1 - bridge
    # $2 - local device
    # $3 - remote ip
    # $4 - name

    local bridge=$1
    local device=$2
    local remote=$3
    local name=$4

    modprobe ip_gre

    local addr=$(ip addr show ${device} | grep "inet " | awk '{ print $2 }' | cut -d/ -f1)

    if ( ! ip link show dev ${bridge} ); then
        brctl addbr ${bridge}
        ip link set ${bridge} up
    fi

    if [ "${addr}" = "${remote}" ]; then
        # can't link to myself.  duh.
        return 0
    fi

    ip link add gretap.${name} type gretap local ${addr} remote ${remote}
    ip link set dev gretap.${name} up
    brctl addif ${bridge} gretap.${name}
}


# throw eth0 into br100 and swap ips.
function bridge_whoop_de_do() {
    if [ $PLATFORM = "debian" ] || [ $PLATFORM = "ubuntu" ]; then
        install_package "bridge-utils"
    fi

    # get the eth0 addr
    local addr=$(ip addr show eth0 | grep "inet " | awk '{ print $2 }')

    ip addr del ${addr} dev eth0
    ifconfig eth0 down
    brctl addbr br100
    brctl addif br100 eth0
    ifconfig eth0 up
    ifconfig br100 up ${addr}

    ifconfig -a
    ps auxw
}

function template_client() {
    # $1 - IP
    local ip=$1
    local env=${2:-${CHEF_ENV}}

    sed /etc/chef/client-template.rb -s -e s/@IP@/${ip}/ > /etc/chef/client.rb
    echo "environment '${env}'" >> /etc/chef/client.rb
}

function flush_iptables() {
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    iptables -t mangle -F
    iptables -t mangle -X
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
}

function fix_for_tests_quantum() {
    if [ $PLATFORM = "debian" ] || [ $PLATFORM = "ubuntu" ]; then
        install_package "swift"
    elif [ $PLATFORM = "redhat" ] || [ $PLATFORM = "centos" ]; then
        install_package "openstack-swift"
    fi
    ip addr add 192.168.1.254/24 dev eth2 || true
}

function fix_for_tests() {
    local IP=${1:-192.168.100.254}
    # add a couple packages and install the route for the bridge when using gre tunnelling
    if [ $PLATFORM = "debian" ] || [ $PLATFORM = "ubuntu" ]; then
        install_package "swift"
    elif [ $PLATFORM = "redhat" ] || [ $PLATFORM = "centos" ]; then
        install_package "openstack-swift"
    fi
    ip addr add ${IP}/24 dev br99 || true
}
