#!/bin/sh -e
sed -e '1,/^exit$/d' "$0" | tar xzpf - && rm ./openstack-deploy
exit
