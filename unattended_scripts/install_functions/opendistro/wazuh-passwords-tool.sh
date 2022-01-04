#!/bin/bash

# Tool to change the passwords of Open Distro internal users
# Copyright (C) 2015-2021, Wazuh Inc.
#
# This program is a free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public
# License (version 2) as published by the FSF - Free Software
# Foundation.

logfile="/var/log/wazuh-password-tool.sh"
debug_pass=">> ${logfile} 2>&1"
if [ -n "$(command -v yum)" ]; then
    sys_type="yum"
elif [ -n "$(command -v zypper)" ]; then
    sys_type="zypper"   
elif [ -n "$(command -v apt-get)" ]; then
    sys_type="apt-get"   
fi

changePassword() {
    
    if [ -n "${changeall}" ]; then
        for i in "${!passwords[@]}"
        do  
            if [ -n "${elasticsearchinstalled}" ]; then
                awk -v new=${hashes[i]} 'prev=="'${users[i]}':"{sub(/\042.*/,""); $0=$0 new} {prev=$1} 1' /usr/share/elasticsearch/backup/internal_users.yml > internal_users.yml_tmp && mv -f internal_users.yml_tmp /usr/share/elasticsearch/backup/internal_users.yml
            fi
            
            if [ "${users[i]}" == "admin" ]; then
                wazuhpass=${passwords[i]}
            elif [ "${users[i]}" == "kibanaserver" ]; then
                kibpass=${passwords[i]}
            fi  

        done
    else
        if [ -n "${elasticsearchinstalled}" ]; then
            awk -v new="$hash" 'prev=="'${nuser}':"{sub(/\042.*/,""); $0=$0 new} {prev=$1} 1' /usr/share/elasticsearch/backup/internal_users.yml > internal_users.yml_tmp && mv -f internal_users.yml_tmp /usr/share/elasticsearch/backup/internal_users.yml
        fi

        if [ "${nuser}" == "wazuh" ]; then
            wazuhpass=${password}
        elif [ "${nuser}" == "kibanaserver" ]; then
            kibpass=${password}
        fi        

    fi
    
    if [ "${nuser}" == "admin" ] || [ -n "${changeall}" ]; then

        if [ -n "${filebeatinstalled}" ]; then
            wazuhold=$(grep "password:" /etc/filebeat/filebeat.yml )
            ra="  password: "
            wazuhold="${wazuhold//$ra}"
            conf="$(awk '{sub("password: .*", "password: '${wazuhpass}'")}1' /etc/filebeat/filebeat.yml)"
            echo "${conf}" > /etc/filebeat/filebeat.yml  
            restartService "filebeat"
        fi 
    fi

    if [ "$nuser" == "kibanaserver" ] || [ -n "$changeall" ]; then

        if [ -n "${kibanainstalled}" ] && [ -n "${kibpass}" ]; then
            wazuhkibold=$(grep "password:" /etc/kibana/kibana.yml )
            rk="elasticsearch.password: "
            wazuhkibold="${wazuhkibold//$rk}"
            conf="$(awk '{sub("elasticsearch.password: .*", "elasticsearch.password: '${kibpass}'")}1' /etc/kibana/kibana.yml)"
            echo "${conf}" > /etc/kibana/kibana.yml 
            restartService "kibana"
        fi         
    fi

}

checkInstalledPass() {
    
    if [ "${sys_type}" == "yum" ]; then
        elasticsearchinstalled=$(yum list installed 2>/dev/null | grep elasticsearch-oss)
    elif [ "${sys_type}" == "zypper" ]; then
        elasticsearchinstalled=$(zypper packages | grep elasticsearch-oss | grep i+ | grep noarch)
    elif [ "${sys_type}" == "apt-get" ]; then
        elasticsearchinstalled=$(apt list --installed  2>/dev/null | grep 'elasticsearch-oss*')
    fi 

    if [ "${sys_type}" == "yum" ]; then
        filebeatinstalled=$(yum list installed 2>/dev/null | grep filebeat)
    elif [ "${sys_type}" == "zypper" ]; then
        filebeatinstalled=$(zypper packages | grep filebeat | grep i+ | grep noarch)
    elif [ "${sys_type}" == "apt-get" ]; then
        filebeatinstalled=$(apt list --installed  2>/dev/null | grep filebeat)
    fi 

    if [ -n "${filebeatinstalled}" ]; then
        if [ "${sys_type}" == "zypper" ]; then
            filebeatversion=$(echo ${filebeatinstalled} | awk '{print $11}')
        else
            filebeatversion=$(echo ${filebeatinstalled} | awk '{print $2}')
        fi  
    fi    

    if [ "${sys_type}" == "yum" ]; then
        kibanainstalled=$(yum list installed 2>/dev/null | grep opendistroforelasticsearch-kibana)
    elif [ "${sys_type}" == "zypper" ]; then
        kibanainstalled=$(zypper packages | grep opendistroforelasticsearch-kibana | grep i+)
    elif [ "${sys_type}" == "apt-get" ]; then
        kibanainstalled=$(apt list --installed  2>/dev/null | grep opendistroforelasticsearch-kibana)
    fi 

    if [ -n "${kibanainstalled}" ]; then
        if [ "${sys_type}" == "zypper" ]; then
            kibanaversion=$(echo ${kibanainstalled} | awk '{print $11}')
        else
            kibanaversion=$(echo ${kibanainstalled} | awk '{print $2}')
        fi  
    fi 

    if [ -z "${elasticsearchinstalled}" ] && [ -z "${kibanainstalled}" ] && [ -z "${filebeatinstalled}" ]; then
        logger_pass -e "Open Distro is not installed on the system."
        exit 1;
    else
        if [ -n "${elasticsearchinstalled}" ]; then
            capem=$(grep "opendistro_security.ssl.transport.pemtrustedcas_filepath: " /etc/elasticsearch/elasticsearch.yml )
            rcapem="opendistro_security.ssl.transport.pemtrustedcas_filepath: "
            capem="${capem//$rcapem}"
            if [[ -z "${adminpem}" ]] || [[ -z "${adminkey}" ]]; then
                readAdmincerts
            fi
        fi
    fi

}

checkRoot() {

    if [ "$EUID" -ne 0 ]; then
        logger_pass -e "This script must be run as root."
        exit 1;
    fi 

}

checkUser() {

    for i in "${!users[@]}"; do
        if [ ${users[i]} == $nuser ]; then
            exists=1
        fi
    done

    if [ -z "${exists}" ]; then
        logger_pass -e "The given user does not exist"
        exit 1;
    fi

}

createBackUp() {
    
    logger_pass "Creating password backup."
    eval "mkdir /usr/share/elasticsearch/backup ${debug_pass}"
    eval "/usr/share/elasticsearch/plugins/opendistro_security/tools/securityadmin.sh -backup /usr/share/elasticsearch/backup -nhnv -cacert ${capem} -cert ${adminpem} -key ${adminkey} -icl -h ${IP} ${debug_pass}"
    if [  "$?" != 0  ]; then
        logger_pass -e "The backup could not be created"
        exit 1;
    fi
    logger_pass "Password backup created"
    
}

generateHash() {
    
    if [ -n "${changeall}" ]; then
        logger_pass "Generating password hashes."
        for i in "${!passwords[@]}"
        do
            nhash=$(bash /usr/share/elasticsearch/plugins/opendistro_security/tools/hash.sh -p ${passwords[i]} | grep -v WARNING)
            hashes+=(${nhash})
        done
        logger_pass "Password hashes generated."
    else
        logger_pass "Generating password hash"
        hash=$(bash /usr/share/elasticsearch/plugins/opendistro_security/tools/hash.sh -p ${password} | grep -v WARNING)
        if [  "$?" != 0  ]; then
            logger_pass -e "Hash generation failed."
            exit 1;
        fi    
        logger_pass "Password hash generated."
    fi

}

generatePassword() {

    if [ -n "${nuser}" ]; then
        logger_pass "Generating random password"
        password=$(< /dev/urandom tr -dc A-Za-z0-9 | head -c${1:-32};echo;)
    else
        logger_pass "Generating random passwords."
        for i in "${!users[@]}"; do
            PASS=$(< /dev/urandom tr -dc A-Za-z0-9 | head -c${1:-32};echo;)
            passwords+=(${PASS})
        done
    fi

        if [  "$?" != 0  ]; then
        logger_pass -e "The password has not been generated."
        exit 1;
    fi

}

generatePasswordFile() {

    users=( admin kibanaserver kibanaro logstash readall snapshotrestore wazuh_admin wazuh_user)
    generatePassword
    for i in "${!users[@]}"; do
        echo "User:" >> ${gen_file}
        echo "  name: ${users[${i}]}" >> ${gen_file}
        echo "  password: ${passwords[${i}]}" >> ${gen_file}
    done

}

getHelp() {

    echo -e ""
    echo -e "NAME"
    echo -e "        $(basename $0) - Manage passwords for OpenDistro users."
    echo -e ""
    echo -e "SYNOPSIS"
    echo -e "        $(basename $0) [OPTIONS]"
    echo -e ""
    echo -e "DESCRIPTION"
    echo -e "        -a,  --change-all"
    echo -e "                Changes all the Open Distro user passwords and prints them on screen."
    echo -e ""
    echo -e "        -u,  --user <user>"
    echo -e "                Indicates the name of the user whose password will be changed." 
    echo -e "                If no password specified it will generate a random one."
    echo -e ""
    echo -e "        -p,  --password <password>"
    echo -e "                Indicates the new password, must be used with option -u."
    echo -e ""
    echo -e "        -c,  --cert <route-admin-certificate>"
    echo -e "                Indicates route to the admin certificate"
    echo -e ""
    echo -e "        -k,  --certkey <route-admin-certificate-key>"
    echo -e "                Indicates route to the admin certificate key".
    echo -e ""
    echo -e "        -v,  --verbose"
    echo -e "                Shows the complete script execution output".
    echo -e ""
    echo -e "        -f,  --file <password_file.yml>"
    echo -e "                Changes the passwords for the ones given in the file."
    echo -e "                Each user has to have this format."
    echo -e ""
    echo -e "                    User:"
    echo -e "                        name: <user>"
    echo -e "                        password: <password>"
    echo -e ""
    echo -e "        -gf, --generate-file <password_file.yml>"
    echo -e "                Generate password file with random passwords for standard users"
    echo -e ""
    echo -e "        -h,  --help"
    echo -e "                Shows help"
    echo -e ""
    exit 1

}

getNetworkHost() {

    IP=$(grep -hr "network.host:" /etc/elasticsearch/elasticsearch.yml)
    NH="network.host: "
    IP="${IP//$NH}"
    
    if [[ ${IP} == "0.0.0.0" ]]; then
        IP="localhost"
    fi

}

logger_pass() {

    now=$(date +'%m/%d/%Y %H:%M:%S')
    case $1 in 
        "-e")
            mtype="ERROR:"
            message="$2"
            ;;
        "-w")
            mtype="WARNING:"
            message="$2"
            ;;
        *)
            mtype="INFO:"
            message="$1"
            ;;
    esac
    echo $now $mtype $message | tee -a ${logfile}

}

main() {   

    if [ -n "$1" ]; then      
        while [ -n "$1" ]
        do
            case "$1" in
            "-v"|"--verbose")
                verboseenabled=1
                shift 1
                ;;
            "-a"|"--change-all")
                changeall=1
                shift 1
                ;;                
            "-u"|"--user")
                nuser=$2
                shift
                shift
                ;;
            "-p"|"--password")
                password=$2
                shift
                shift
                ;;
            "-c"|"--cert")
                adminpem=$2
                shift
                shift
                ;; 
            "-k"|"--certkey")
                adminkey=$2
                shift
                shift
                ;; 
            "-f"|"--file")
                p_file=$2
                shift
                shift
                ;;
            "-gf"|"--generate-file")
                gen_file=$2
                shift
                shift
                ;;  
            "-h"|"--help")
                getHelp
                ;;
            *)
                getHelp
            esac
        done

        export JAVA_HOME=/usr/share/elasticsearch/jdk/
        
        if [ -n "${verboseenabled}" ]; then
            debug_pass="2>&1 | tee -a ${logfile}"
        fi 

        if [ -n "${gen_file}" ]; then
            generatePasswordFile 
            if [ -z "${p_file}" ] && [ -z "${nuser}" ] && [ -z "${changeall}" ]; then
                exit 0
            fi
        fi

        checkInstalledPass   

        if [ -n "${p_file}" ] && [ ! -f "${p_file}" ]; then
            getHelp
        fi

        if [ -n "${nuser}" ] && [ -n "${changeall}" ]; then
            getHelp
        fi 

        if [ -n "${password}" ] && [ -n "${changeall}" ]; then
            getHelp
        fi 
        
        if [ -n "${nuser}" ] && [ -n "${p_file}" ]; then
            getHelp
        fi 

        if [ -n "${password}" ] && [ -n "${p_file}" ]; then
            getHelp
        fi         

        if [ -z "${nuser}" ] && [ -n "${password}" ]; then
            getHelp
        fi   

        if [ -z "${nuser}" ] && [ -z "${password}" ] && [ -z "${changeall}" ] && [ -z  "${p_file}" ]; then
            getHelp
        fi 

        if [ -n "${nuser}" ]; then
            readUsers
            checkUser
        fi          

        if [ -n "${nuser}" ] && [ -z "${password}" ]; then
            autopass=1
            generatePassword
        fi

        if [ -n "${changeall}" ]; then
            readUsers
            generatePassword
        fi               

        if [ -n "${p_file}" ] && [ -z "${changeall}" ]; then
            readUsers
        fi	    

        if [ -n "${p_file}" ]; then
            readFileUsers
        fi  

        getNetworkHost
        createBackUp
        generateHash
        changePassword
        runSecurityAdmin

    else

        getHelp        

    fi

}

readAdmincerts() {

    if [[ -f /etc/elasticsearch/certs/admin.pem ]]; then
        adminpem="/etc/elasticsearch/certs/admin.pem"
    else
        logger_pass -e "No admin certificate indicated. Please run the script with the option -c <path-to-certificate>."
        exit 1;
    fi

    if [[ -f /etc/elasticsearch/certs/admin-key.pem ]]; then
        adminkey="/etc/elasticsearch/certs/admin-key.pem"
    elif [[ -f /etc/elasticsearch/certs/admin.key ]]; then
        adminkey="/etc/elasticsearch/certs/admin.key"
    else
        logger_pass -e "No admin certificate key indicated. Please run the script with the option -k <path-to-key-certificate>."
        exit 1;
    fi    

}

readFileUsers() {

    filecorrect=$(grep -Pzc '\A(User:\s*name:\s*\w+\s*password:\s*[A-Za-z0-9_\-]+\s*)+\Z' ${p_file})
    if [ "${filecorrect}" -ne 1 ]; then
	logger_pass -e "The password file doesn't have a correct format.

It must have this format:
User:
   name: wazuh
   password: wazuhpassword
User:
   name: kibanaserver
   password: kibanaserverpassword"
	exit 1
    fi	

    if [ ! -n "$users" ]; then 
        if [ -n "${kibanainstalled}" ] && [ -z "${changeall}" ]; then 
            users=( kibanaserver admin )
        fi

        if [ -n "${filebeatinstalled}" ] && [ -z "${changeall}" ]; then 
            users=( admin )
        fi
    fi

    sfileusers=$(grep name: ${p_file} | awk '{ print substr( $2, 1, length($2) ) }')
    sfilepasswords=$(grep password: ${p_file} | awk '{ print substr( $2, 1, length($2) ) }')

    fileusers=($sfileusers)
    filepasswords=($sfilepasswords)

    if [ -n "${verboseenabled}" ]; then
        logger_pass "Users in the file: ${fileusers[@]}"
        logger_pass "Passwords in the file: ${filepasswords[@]}"
    fi

    if [ -n "${changeall}" ]; then
        for j in "${!fileusers[@]}"; do
            supported=false
            for i in "${!users[@]}"; do
                if [[ ${users[i]} == ${fileusers[j]} ]]; then
                    passwords[i]=${filepasswords[j]}
                    supported=true
                fi
            done
            if [ "${supported}" = false ] && [ -n "${elasticsearchinstalled}" ]; then
                logger_pass -e "The given user ${fileusers[j]} does not exist"
            fi
        done
    else
        finalusers=()
        finalpasswords=()

        for j in "${!fileusers[@]}"; do
            supported=false
            for i in "${!users[@]}"; do
                if [[ "${users[i]}" == "${fileusers[j]}" ]]; then
                    finalusers+=(${fileusers[j]})
                    finalpasswords+=(${filepasswords[j]})
                    supported=true
                fi
            done
            if [ ${supported} = false ] && [ -n "${elasticsearchinstalled}" ]; then
                logger_pass -e "The given user ${fileusers[j]} does not exist"
            fi
        done

        users=()
        users=(${finalusers[@]})
        passwords=(${finalpasswords[@]})
        changeall=1
    fi

}

readUsers() {

    susers=$(grep -B 1 hash: /usr/share/elasticsearch/plugins/opendistro_security/securityconfig/internal_users.yml | grep -v hash: | grep -v "-" | awk '{ print substr( $0, 1, length($0)-1 ) }')
    users=($susers)  

}

restartService() {

    if [ -n "$(ps -e | egrep ^\ *1\ .*systemd$)" ]; then
        eval "systemctl restart $1.service ${debug_pass}"
        if [  "$?" != 0  ]; then
            logger_pass -e "${1^} could not be started."
            exit 1;
        else
            logger_pass "${1^} started"
        fi  
    elif [ -n "$(ps -e | egrep ^\ *1\ .*init$)" ]; then
        eval "/etc/init.d/$1 restart ${debug_pass}"
        if [  "$?" != 0  ]; then
            logger_pass -e "${1^} could not be started."
            exit 1;
        else
            logger_pass "${1^} started"
        fi     
    elif [ -x "/etc/rc.d/init.d/$1" ] ; then
        eval "/etc/rc.d/init.d/$1 restart ${debug_pass}"
        if [  "$?" != 0  ]; then
            logger_pass -e "${1^} could not be started."
            exit 1;
        else
            logger_pass "${1^} started"
        fi             
    else
        logger_pass -e "${1^} could not start. No service manager found on the system."
        exit 1;
    fi

}

runSecurityAdmin() {
    
    logger_pass "Loading new passwords changes."
    eval "cp /usr/share/elasticsearch/backup/* /usr/share/elasticsearch/plugins/opendistro_security/securityconfig/ ${debug_pass}"
    eval "/usr/share/elasticsearch/plugins/opendistro_security/tools/securityadmin.sh -cd /usr/share/elasticsearch/plugins/opendistro_security/securityconfig/ -nhnv -cacert ${capem} -cert ${adminpem} -key ${adminkey} -icl -h ${IP} ${debug_pass}"
    if [  "$?" != 0  ]; then
        logger_pass -e "Could not load the changes."
        exit 1;
    fi    
    eval "rm -rf /usr/share/elasticsearch/backup/ ${debug_pass}"

    if [[ -n "${nuser}" ]] && [[ -n ${autopass} ]]; then
        logger_pass $'\nThe password for user '${nuser}' is '${password}''
        logger_pass -w "Password changed. Remember to update the password in /etc/filebeat/filebeat.yml and /etc/kibana/kibana.yml if necessary and restart the services."
    fi

    if [[ -n "${nuser}" ]] && [[ -z ${autopass} ]]; then
        logger_pass -w "Password changed. Remember to update the password in /etc/filebeat/filebeat.yml and /etc/kibana/kibana.yml if necessary and restart the services."
    fi    

    if [ -n "${changeall}" ]; then
        logger_pass -w "Passwords changed. Remember to update the password in /etc/filebeat/filebeat.yml and /etc/kibana/kibana.yml if necessary and restart the services."
    fi 

}

main $@
