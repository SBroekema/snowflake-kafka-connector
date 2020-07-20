#!/bin/bash

# exit on error
set -e

# error printing function
function error_exit() {
    echo >&2 $1
    exit 1
}

function random-string() {
    cat /dev/urandom | env LC_CTYPE=C tr -cd 'a-z0-9' | head -c 4 
}

source ./utils.sh

# check argument number
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ] ; then
    error_exit "Usage: ./run_test.sh <version> <path to apache config folder> <pressure>.  Aborting."
fi

CONFLUENT_VERSION=$1
SNOWFLAKE_APACHE_CONFIG_PATH=$2
if [ "$#" -eq 3 ] ; then
  PRESSURE=$3
else
  PRESSURE="false"
fi 
SNOWFLAKE_ZOOKEEPER_CONFIG="zookeeper.properties"
SNOWFLAKE_KAFKA_CONFIG="server.properties"
SNOWFLAKE_KAFKA_CONNECT_CONFIG="connect-distributed.properties"
SNOWFLAKE_SCHEMA_REGISTRY_CONFIG="schema-registry.properties"

if [ ! -d "$SNOWFLAKE_APACHE_CONFIG_PATH" ]; then
    error_exit "Provided snowflake apache config folder $SNOWFLAKE_APACHE_CONFIG_PATH does not exist.  Aborting."
fi

if [ ! -f "$SNOWFLAKE_APACHE_CONFIG_PATH/$SNOWFLAKE_ZOOKEEPER_CONFIG" ]; then
    error_exit "Zookeeper config $SNOWFLAKE_APACHE_CONFIG_PATH/$SNOWFLAKE_ZOOKEEPER_CONFIG does not exist.  Aborting."
fi

if [ ! -f "$SNOWFLAKE_APACHE_CONFIG_PATH/$SNOWFLAKE_KAFKA_CONFIG" ]; then
    error_exit "Kafka config $SNOWFLAKE_APACHE_CONFIG_PATH/$SNOWFLAKE_KAFKA_CONFIG does not exist.  Aborting."
fi

if [ ! -f "$SNOWFLAKE_APACHE_CONFIG_PATH/$SNOWFLAKE_KAFKA_CONNECT_CONFIG" ]; then
    error_exit "Kafka Connect config $SNOWFLAKE_APACHE_CONFIG_PATH/$SNOWFLAKE_KAFKA_CONNECT_CONFIG does not exist.  Aborting."
fi

# require two environment variables for credentials
if [[ -z "${SNOWFLAKE_CREDENTIAL_FILE}" ]]; then
    error_exit "Require environment variable SNOWFLAKE_CREDENTIAL_FILE but it's not set.  Aborting."
fi

if [ ! -f "$SNOWFLAKE_CREDENTIAL_FILE" ]; then
    error_exit "Provided SNOWFLAKE_CREDENTIAL_FILE $SNOWFLAKE_CREDENTIAL_FILE does not exist.  Aborting."
fi

TEST_SET="confluent"

# check if all required commands are installed
# assume that helm and kubectl are configured

command -v python3 >/dev/null 2>&1 || error_exit "Require python3 but it's not installed.  Aborting."

APACHE_LOG_PATH="./apache_log"

NAME_SALT=$(random-string)
NAME_SALT="_$NAME_SALT"
echo -e "=== Name Salt: $NAME_SALT ==="

# start apache kafka cluster
case $CONFLUENT_VERSION in
	5.0.0)
    DOWNLOAD_URL="https://packages.confluent.io/archive/5.0/confluent-oss-5.0.0-2.11.tar.gz"
		;;
	5.1.0)
    DOWNLOAD_URL="https://packages.confluent.io/archive/5.1/confluent-community-5.1.0-2.11.tar.gz"
    ;;
	5.*.0)
    c_version=${CONFLUENT_VERSION%.0}
    DOWNLOAD_URL="https://packages.confluent.io/archive/$c_version/confluent-community-$c_version.0-2.11.tar.gz"
    ;;
  *)
    error_exit "Usage: ./run_test.sh <version> <path to apache config folder>. Unknown version $CONFLUENT_VERSION Aborting."
esac

CONFLUENT_FOLDER_NAME="./confluent-$CONFLUENT_VERSION"

rm -rf $CONFLUENT_FOLDER_NAME || true
#rm apache.tgz || true

#curl $DOWNLOAD_URL --output apache.tgz
tar xzvf apache.tgz > /dev/null 2>&1

mkdir -p $APACHE_LOG_PATH
rm $APACHE_LOG_PATH/zookeeper.log $APACHE_LOG_PATH/kafka.log $APACHE_LOG_PATH/kc.log || true
rm -rf /tmp/kafka-logs /tmp/zookeeper || true

# Copy protobuf data to Kafka Connect
PROTOBUF_FOLDER="./test_data/protobuf"
PROTOBUF_TARGET="target"
PROTOBUF_JAR_NAME="kafka-test-protobuf-1.0-SNAPSHOT.jar"
PROTOBUF_INSTALL_FOLDER="$CONFLUENT_FOLDER_NAME/share/java/kafka-serde-tools"
pushd $PROTOBUF_FOLDER
mvn clean package
cp $PROTOBUF_TARGET/$PROTOBUF_JAR_NAME ../../$PROTOBUF_INSTALL_FOLDER || true
echo -e "\n=== copied protobuf data to $PROTOBUF_INSTALL_FOLDER ==="
popd

PROTOBUF_CONVERTER="./test_jar/kafka-connect-protobuf-converter-3.1.1-SNAPSHOT-jar-with-dependencies.jar"
cp $PROTOBUF_CONVERTER $PROTOBUF_INSTALL_FOLDER || true
echo -e "\n=== copied protobuf converter to $PROTOBUF_INSTALL_FOLDER ==="

trap "pkill -9 -P $$" SIGINT SIGTERM EXIT

echo -e "\n=== Start Zookeeper ==="
$CONFLUENT_FOLDER_NAME/bin/zookeeper-server-start $SNOWFLAKE_APACHE_CONFIG_PATH/$SNOWFLAKE_ZOOKEEPER_CONFIG > $APACHE_LOG_PATH/zookeeper.log 2>&1 &
sleep 10
echo -e "\n=== Start Kafka ==="
$CONFLUENT_FOLDER_NAME/bin/kafka-server-start $SNOWFLAKE_APACHE_CONFIG_PATH/$SNOWFLAKE_KAFKA_CONFIG > $APACHE_LOG_PATH/kafka.log 2>&1 &
sleep 10
echo -e "\n=== Start Kafka Connect ==="
$CONFLUENT_FOLDER_NAME/bin/connect-distributed $SNOWFLAKE_APACHE_CONFIG_PATH/$SNOWFLAKE_KAFKA_CONNECT_CONFIG > $APACHE_LOG_PATH/kc.log 2>&1 &
sleep 10
echo -e "\n=== Start Schema Registry ==="
$CONFLUENT_FOLDER_NAME/bin/schema-registry-start $SNOWFLAKE_APACHE_CONFIG_PATH/$SNOWFLAKE_SCHEMA_REGISTRY_CONFIG > $APACHE_LOG_PATH/sc.log 2>&1 &
sleep 30

# address of kafka
SNOWFLAKE_KAFKA_PORT="9092"
LOCAL_IP="localhost"
SC_PORT=8081
KC_PORT=8083

set +e
echo -e "\n=== Clean table stage and pipe ==="
python3 test_verify.py $LOCAL_IP:$SNOWFLAKE_KAFKA_PORT http://$LOCAL_IP:$SC_PORT clean $NAME_SALT $PRESSURE

record_thread_count 2>&1 &
create_connectors_with_salt $SNOWFLAKE_CREDENTIAL_FILE $NAME_SALT $LOCAL_IP $KC_PORT
# Send test data and verify DB result from Python
python3 test_verify.py $LOCAL_IP:$SNOWFLAKE_KAFKA_PORT http://$LOCAL_IP:$SC_PORT $TEST_SET $NAME_SALT $PRESSURE
testError=$?
delete_connectors_with_salt $NAME_SALT $LOCAL_IP $KC_PORT
python3 test_verify.py $LOCAL_IP:$SNOWFLAKE_KAFKA_PORT http://$LOCAL_IP:$SC_PORT clean $NAME_SALT $PRESSURE

##### Following commented code is used to track thread leak
#sleep 100
#
#delete_connectors_with_salt $NAME_SALT $LOCAL_IP $KC_PORT
#NAME_SALT=$(random-string)
#NAME_SALT="_$NAME_SALT"
#echo -e "=== Name Salt: $NAME_SALT ==="
#create_connectors_with_salt $SNOWFLAKE_CREDENTIAL_FILE $NAME_SALT $LOCAL_IP $KC_PORT
#python3 test_verify.py $LOCAL_IP:$SNOWFLAKE_KAFKA_PORT http://$LOCAL_IP:$SC_PORT $TEST_SET $NAME_SALT $PRESSURE
#
#sleep 100
#
#delete_connectors_with_salt $NAME_SALT $LOCAL_IP $KC_PORT
#NAME_SALT=$(random-string)
#NAME_SALT="_$NAME_SALT"
#echo -e "=== Name Salt: $NAME_SALT ==="
#create_connectors_with_salt $SNOWFLAKE_CREDENTIAL_FILE $NAME_SALT $LOCAL_IP $KC_PORT
#python3 test_verify.py $LOCAL_IP:$SNOWFLAKE_KAFKA_PORT http://$LOCAL_IP:$SC_PORT $TEST_SET $NAME_SALT $PRESSURE

if [ $testError -ne 0 ]; then
    RED='\033[0;31m'
    NC='\033[0m' # No Color
    echo -e "${RED} There is error above this line ${NC}"
    tail -200 $APACHE_LOG_PATH/zookeeper.log
    tail -200 $APACHE_LOG_PATH/kafka.log
    tail -200 $APACHE_LOG_PATH/kc.log
    tail -200 $APACHE_LOG_PATH/sc.log
    error_exit "=== test_verify.py failed ==="
fi
