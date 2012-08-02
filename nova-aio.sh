#!/bin/bash

INSTANCE_IMAGE=6faf41e1-5029-4cdb-8a66-8559b7bd1f1f

source $(dirname $0)/chef-jenkins.sh

init

declare -a cluster
cluster=(nova-aio)

boot_and_wait chef-server
wait_for_ssh $(ip_for_host chef-server)

x_with_server "Uploading chef cookbooks" chef-server <<EOF
apt-get update
flush_iptables
install_package git-core
rabbitmq_fixup
chef_fixup
checkout_cookbooks
upload_cookbooks
upload_roles
EOF
background_task "fc_do"

boot_cluster ${cluster[@]}
wait_for_cluster_ssh ${cluster[@]}

echo "Cluster booted... configuring chef"

# at this point, chef server is done, cluster is up.
# let's set up the environment.

create_chef_environment chef-server nova-aio

x_with_cluster "Installing/registering chef client" nova-aio <<EOF
apt-get update
flush_iptables
install_chef_client
fetch_validation_pem $(ip_for_host chef-server)
copy_file client-template.rb /etc/chef/client-template.rb
template_client $(ip_for_host chef-server)
chef-client -ldebug
EOF

# clients are all kicked and inserted into chef server.  Need to
# set up the proper roles for the nodes and go.
role_add chef-server nova-aio "role[single-controller]"
role_add chef-server nova-aio "role[single-compute]"
role_add chef-server nova-aio "recipe[kong]"
role_add chef-server nova-aio "recipe[exerstack]"
set_environment chef-server nova-aio nova-aio

x_with_cluster "Running first chef pass" nova-aio <<EOF
chef-client -ldebug
EOF

if ( ! run_tests nova-aio essex-final ); then
    echo "Tests failed."
    exit 1
fi

# let's grab the logs
cluster_fetch_file "/etc/{nova,glance,keystone}/*log" ./logs

if [ ! -z "${BUILD_URL}" ] && [ ! -z "${GIT_COMMENT_URL:-}" ]; then
    msg="Gate: Nova AIO\n * ${BUILD_URL}consoleFull : SUCCESS"
    github_post_comment ${GIT_COMMENT_URL} ${msg}
fi
