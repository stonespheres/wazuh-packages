from datetime import datetime
import pytest
import time
import os
import re
import json
import sys
import platform
from subprocess import Popen, PIPE, check_output
import yaml
import requests
import urllib
import socket
from base64 import b64encode
import warnings
import subprocess
from subprocess import check_call
from bs4 import BeautifulSoup
warnings.filterwarnings('ignore', message='Unverified HTTPS request')

# ----------------------------- Aux functions -----------------------------


services = None
p = Popen(['/var/ossec/bin/wazuh-control', 'status'], stdin=PIPE, stdout=PIPE, stderr=PIPE)
if sys.version_info[0] < 3:
    services = p.stdout.read()
else:
    services = p.stdout
p.kill()

def get_indexer_password():
    stream = open("/etc/filebeat/filebeat.yml", 'r')
    dictionary = yaml.safe_load(stream)
    return (dictionary.get('output.elasticsearch','password').get('password'))

def get_indexer_username():
    stream = open("/etc/filebeat/filebeat.yml", 'r')
    dictionary = yaml.safe_load(stream)
    return (dictionary.get('output.elasticsearch','username').get('username'))

def get_indexer_ip():
    stream = open("/etc/wazuh-indexer/opensearch.yml", 'r')
    dictionary = yaml.safe_load(stream)
    return (dictionary.get('network.host'))

def api_call_elasticsearch(host,query,address,api_protocol,api_user,api_pass,api_port):

    if (query == ""):   # Calling ES API without query
        if (api_pass != "" and api_pass != ""): # If credentials provided
            response = subprocess.check_output("curl --max-time 15"
                                + " -k -u "     + api_user + ":" + api_pass + " "
                                + api_protocol + "://" + address + ":" + api_port,
                                shell=True)
        else:
            response = subprocess.check_output("curl --max-time 15 " + api_protocol + "://" + address + ":" + api_port, shell=True)

    elif (query != ""): # Executing query search
        if (api_pass != "" and api_pass != ""):
            response = subprocess.check_output("curl -H \'Content-Type: application/json\'"
                                + " --max-time 15"
                                + " -k -u "     + api_user + ":" + api_pass
                                + " -d '"        + json.dumps(query) + "' "
                                + api_protocol + "://" + address + ":" + api_port
                                + "/wazuh-alerts-4.x-*/_search",
                                shell=True)
        else:
            response = subprocess.check_output("curl --max-time 15 " + api_protocol + "://" + address + ":" + api_port, shell=True)

    else:
        response = "Error. Unable to classify Elasticsearch API call"

    return response

def get_dashboards_password():
    stream = open("/etc/wazuh-dashboards/dashboards.yml", 'r')
    dictionary = yaml.safe_load(stream)
    return (dictionary.get('opensearch.password'))

def get_dashboards_username():
    stream = open("/etc/wazuh-dashboards/dashboards.yml", 'r')
    dictionary = yaml.safe_load(stream)
    return (dictionary.get('opensearch.username'))

def get_elasticsearch_cluster_status():
    ip = get_indexer_ip()
    resp = requests.get('https://'+ip+':9700/_cluster/health',
                        auth=(get_indexer_username(),
                        get_indexer_password()),
                        verify=False)
    return (resp.json()['status'])

def get_kibana_status():
    ip = get_indexer_ip()
    resp = requests.get('https://'+ip,
                        auth=(get_kibana_username(),
                        get_kibana_password()),
                        verify=False)
    return (resp.status_code)

def get_wazuh_api_status():

    protocol = 'https'
    host = get_indexer_ip()
    port = 55000
    user = 'wazuh'
    password = 'wazuh'
    login_endpoint = 'security/user/authenticate'

    login_url = f"{protocol}://{host}:{port}/{login_endpoint}"
    basic_auth = f"{user}:{password}".encode()
    login_headers = {'Content-Type': 'application/json',
                    'Authorization': f'Basic {b64encode(basic_auth).decode()}'}
    response = requests.get(login_url, headers=login_headers, verify=False)
    token = json.loads(response.content.decode())['data']['token']
    requests_headers = {'Content-Type': 'application/json',
                        'Authorization': f'Bearer {token}'}
    response = requests.get(f"{protocol}://{host}:{port}/?pretty=true", headers=requests_headers, verify=False)

    return response.json()['data']['title']

# ----------------------------- Tests -----------------------------

@pytest.mark.wazuh
def test_check_wazuh_manager_authd():
    assert check_call("ps -xa | grep wazuh-authd | grep -v grep", shell=True) != ""

@pytest.mark.wazuh
def test_check_wazuh_manager_db():
    assert check_call("ps -xa | grep wazuh-db | grep -v grep", shell=True) != ""

@pytest.mark.wazuh
def test_check_wazuh_manager_execd():
    assert check_call("ps -xa | grep wazuh-execd | grep -v grep", shell=True) != ""

@pytest.mark.wazuh
def test_check_wazuh_manager_analysisd():
    assert check_call("ps -xa | grep wazuh-analysisd | grep -v grep", shell=True) != ""

@pytest.mark.wazuh
def test_check_wazuh_manager_syscheckd():
    assert check_call("ps -xa | grep wazuh-syscheckd | grep -v grep", shell=True) != ""

@pytest.mark.wazuh
def test_check_wazuh_manager_remoted():
    assert check_call("ps -xa | grep wazuh-remoted | grep -v grep", shell=True) != ""

@pytest.mark.wazuh
def test_check_wazuh_manager_logcollec():
    assert check_call("ps -xa | grep wazuh-logcollec | grep -v grep", shell=True) != ""

@pytest.mark.wazuh
def test_check_wazuh_manager_monitord():
    assert check_call("ps -xa | grep wazuh-monitord | grep -v grep", shell=True) != ""

@pytest.mark.wazuh
def test_check_wazuh_manager_modulesd():
    assert check_call("ps -xa | grep wazuh-modulesd | grep -v grep", shell=True) != ""

@pytest.mark.wazuh
def test_check_wazuh_manager_apid():
    assert check_call("ps -xa | grep wazuh-apid | grep -v grep", shell=True) != ""

@pytest.mark.wazuh_cluster
def test_check_wazuh_manager_clusterd():
    assert check_call("ps -xa | grep wazuh-clusterd | grep -v grep", shell=True) != ""

@pytest.mark.wazuh
def test_check_filebeat_process():
    assert check_call("ps -xa | grep \"/usr/share/filebeat/bin/filebeat\" | grep -v grep", shell=True) != ""

@pytest.mark.elastic
def test_check_elasticsearch_process():
    assert check_call("ps -xa | grep \"/usr/share/wazuh-indexer/jdk/bin/java\" | grep -v grep | cut -d \" \" -f15", shell=True) != ""

@pytest.mark.kibana
def test_check_kibana_process():
    assert check_call("ps -xa | grep \"/usr/share/kibana/bin/../node/bin/node\" | grep -v grep", shell=True) != ""

@pytest.mark.elastic
def test_check_elasticsearch_cluster_status_not_red():
    assert get_elasticsearch_cluster_status() != "red"

@pytest.mark.elastic_cluster
def test_check_elasticsearch_cluster_status_not_yellow():
    assert get_elasticsearch_cluster_status() != "yellow" 

@pytest.mark.kibana
def test_check_kibana_status():
    assert get_kibana_status() == 200

@pytest.mark.wazuh
def test_test_check_wazuh_api_status():
    assert get_wazuh_api_status() == "Wazuh API REST"

@pytest.mark.wazuh
def test_check_log_errors():
    found_error = False
    with open('/var/ossec/logs/ossec.log', 'r') as f:
        for line in f.readlines():
            if 'ERROR' in line:
                found_error = True
                break
    assert found_error == False, line

@pytest.mark.wazuh_cluster
def test_check_cluster_log_errors():
    found_error = False
    with open('/var/ossec/logs/cluster.log', 'r') as f:
        for line in f.readlines():
            if 'ERROR' in line:
                found_error = True
                break
    assert found_error == False, line

@pytest.mark.wazuh_worker
def test_check_cluster_log_errors():
    found_error = False
    with open('/var/ossec/logs/cluster.log', 'r') as f:
        for line in f.readlines():
            if 'ERROR' in line:
                found_error = True
                break
    assert found_error == False, line

@pytest.mark.wazuh_cluster
def test_check_api_log_errors():
    found_error = False
    with open('/var/ossec/logs/api.log', 'r') as f:
        for line in f.readlines():
            if 'ERROR' in line:
                found_error = True
                break
    assert found_error == False, line

@pytest.mark.elastic
def test_check_alerts():
    node_name = socket.gethostname()
    query = {
        "query": {
            "bool": {
                "must": [
                    {
                        "wildcard": {
                            "agent.name": {
                                "value": node_name
                            }
                        }
                    }
                ]
            }
        }
    }

    response = api_call_elasticsearch(get_indexer_ip(),query,get_indexer_ip(),'https',get_indexer_username(),get_indexer_password(),'9700')
    response_dict = json.loads(response)

    assert (response_dict["hits"]["total"]["value"] > 0)
