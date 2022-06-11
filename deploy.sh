#!/bin/bash

HAL_elasticsearch_ver=7.17.0
HAL_kibana_ver=7.17.0
nginx_ver=latest

# Set your IP address as a variable. This is for instructions below.
IP="$(hostname -I | sed -e 's/[[:space:]]*$//')"

# Update your Host file
echo "${IP} ${HOSTNAME}" | tee -a /etc/hosts

# Update the landing page index file
sed -i "s/host-ip/${IP}/" nginx/landing_page/index.html

# Create SSL certificates
mkdir -p $(pwd)/nginx/ssl
openssl req -newkey rsa:2048 -nodes -keyout $(pwd)/nginx/ssl/HAL.key -x509 -sha256 -days 365 -out $(pwd)/nginx/ssl/HAL.crt -subj "/C=US/ST=HAL/L=HAL/O=HAL/OU=HAL/CN=HAL"

# Create the HAL network and data volume
docker network create HAL


# Create & update Elasticsearch's folder permissions
mkdir -p /var/lib/docker/volumes/elasticsearch{-1,-2,-3}/HAL/_data
chown -R 1000:1000 /var/lib/docker/volumes/elasticsearch{-1,-2,-3}
chown -R 1000:1000 /var/lib/docker/volumes/elasticsearch

# Adjust VM kernel setting for Elasticsearch
sysctl -w vm.max_map_count=262144
bash -c 'cat >> /etc/sysctl.conf <<EOF
vm.max_map_count=262144
EOF'

# Nginx Service
docker run -d  --network HAL --restart unless-stopped --name HAL-landing-page -v $(pwd)/nginx/ssl/HAL.crt:/etc/nginx/HAL.crt:z -v $(pwd)/nginx/ssl/HAL.key:/etc/nginx/HAL.key:z -v $(pwd)/nginx/nginx.conf:/etc/nginx/nginx.conf:z -v $(pwd)/nginx/landing_page:/usr/share/nginx/html:z -p 443:443 nginx:${nginx_ver}

## HAL Monitoring ##

# HAL Elasticsearch Nodes
docker run -d --network HAL --restart unless-stopped --name HAL-elasticsearch-1 -v /var/lib/docker/volumes/elasticsearch-1/HAL/_data:/usr/share/elasticsearch/data:z --ulimit memlock=-1:-1 -p 127.0.0.1:9200:9200 -e "cluster.name=HAL" -e "node.name=HAL-elasticsearch-1" -e "cluster.initial_master_nodes=HAL-elasticsearch-1" -e "bootstrap.memory_lock=true" -e "ES_JAVA_OPTS=-Xms512m -Xmx512m" docker.elastic.co/elasticsearch/elasticsearch:${HAL_elasticsearch_ver}

docker run -d --network HAL --restart unless-stopped --name HAL-elasticsearch-2 -v /var/lib/docker/volumes/elasticsearch-2/HAL/_data:/usr/share/elasticsearch/data:z --ulimit memlock=-1:-1 -e "cluster.name=HAL" -e "node.name=HAL-elasticsearch-2" -e "cluster.initial_master_nodes=HAL-elasticsearch-1" -e "bootstrap.memory_lock=true" -e "ES_JAVA_OPTS=-Xms512m -Xmx512m" -e "discovery.seed_hosts=HAL-elasticsearch-1,HAL-elasticsearch-3" docker.elastic.co/elasticsearch/elasticsearch:${HAL_elasticsearch_ver}

docker run -d --network HAL --restart unless-stopped --name HAL-elasticsearch-3 -v /var/lib/docker/volumes/elasticsearch-3/HAL/_data:/usr/share/elasticsearch/data:z --ulimit memlock=-1:-1 -e "cluster.name=HAL" -e "node.name=HAL-elasticsearch-3" -e "cluster.initial_master_nodes=HAL-elasticsearch-1" -e "bootstrap.memory_lock=true" -e "ES_JAVA_OPTS=-Xms512m -Xmx512m" -e "discovery.seed_hosts=HAL-elasticsearch-1,HAL-elasticsearch-2" docker.elastic.co/elasticsearch/elasticsearch:${HAL_elasticsearch_ver}

# HAL Kibana
docker run -d --network HAL --restart unless-stopped --name HAL-kibana -e SERVER_BASEPATH=/kibana --link HAL-elasticsearch-1:elasticsearch docker.elastic.co/kibana/kibana:${HAL_kibana_ver}

# Wait for Elasticsearch to become available
echo "Elasticsearch takes a bit to negotiate it's cluster settings and come up. Give it a minute."
while true
do
  STATUS=$(curl -sL -o /dev/null -w '%{http_code}' http://127.0.0.1:9200)
  if [ ${STATUS}  200 ]; then
    echo "Elasticsearch is up. Proceeding"
    break
  else
    echo "Elasticsearch still loading. Trying again in 10 seconds"
  fi
  sleep 10
done

# Adjust the Elasticsearch bucket size
curl -X PUT "localhost:9200/_cluster/settings" -H 'Content-Type: application/json' -d'
{
    "persistent" : {
        "search.max_buckets" : "100000000"
    }
}


echo "The HAL landing page has been successfully deployed. Browse to https://${HOSTNAME} (or https://${IP} if you don't have DNS set up) to begin using the services."
