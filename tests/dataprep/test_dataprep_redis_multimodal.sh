#!/bin/bash
# Copyright (C) 2024 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

set -x

WORKPATH=$(dirname "$PWD")
LOG_PATH="$WORKPATH/tests"
ip_address=$(hostname -I | awk '{print $1}')
LVM_PORT=5028
LVM_ENDPOINT="http://${ip_address}:${LVM_PORT}/v1/lvm"
WHISPER_MODEL="base"
INDEX_NAME="dataprep"
tmp_dir=$(mktemp -d)
video_name="WeAreGoingOnBullrun"
transcript_fn="${tmp_dir}/${video_name}.vtt"
video_fn="${tmp_dir}/${video_name}.mp4"
image_name="apple"
image_fn="${tmp_dir}/${image_name}.png"
jpg_image_fn="${tmp_dir}/${image_name}.jpg"
caption_fn="${tmp_dir}/${image_name}.txt"
audio_name="apple"   # Intentionally name the audio file the same as the image for testing image+audio caption
audio_fn="${tmp_dir}/${audio_name}.wav"
pdf_name="nke-10k-2023"
pdf_fn="${tmp_dir}/${pdf_name}.pdf"
export DATAPREP_PORT="11109"
text_ony_pdf_fn="${WORKPATH}/tests/dataprep/ingest_dataprep_text.pdf"

export DATA_PATH=${model_cache}

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source ${SCRIPT_DIR}/dataprep_utils.sh

function build_docker_images() {
    cd $WORKPATH
    echo $(pwd)
    docker build --no-cache -t opea/dataprep:comps --build-arg https_proxy=$https_proxy --build-arg http_proxy=$http_proxy -f comps/dataprep/src/Dockerfile .

    if [ $? -ne 0 ]; then
        echo "opea/dataprep built fail"
        exit 1
    else
        echo "opea/dataprep built successful"
    fi
}

function build_lvm_docker_images() {
    cd $WORKPATH
    echo $(pwd)
    docker build --no-cache -t opea/lvm-llava:comps --build-arg https_proxy=$https_proxy --build-arg http_proxy=$http_proxy -f comps/third_parties/llava/src/Dockerfile .
    if [ $? -ne 0 ]; then
        echo "opea/lvm-llava built fail"
        exit 1
    else
        echo "opea/lvm-llava built successful"
    fi
    docker build --no-cache -t opea/lvm:comps --build-arg https_proxy=$https_proxy --build-arg http_proxy=$http_proxy -f comps/lvms/src/Dockerfile .
    if [ $? -ne 0 ]; then
        echo "opea/lvm built fail"
        exit 1
    else
        echo "opea/lvm built successful"
    fi
}

function start_lvm_service() {
    unset http_proxy
    docker run -d --name="test-comps-lvm-llava" -e http_proxy=$http_proxy -e https_proxy=$https_proxy -p 5029:8399 --ipc=host opea/lvm-llava:comps
    sleep 4m
    docker run -d --name="test-comps-lvm-llava-svc" -e LVM_ENDPOINT=http://$ip_address:5029 -e LVM_COMPONENT_NAME=OPEA_LLAVA_LVM -e http_proxy=$http_proxy -e https_proxy=$https_proxy -p ${LVM_PORT}:9399 --ipc=host opea/lvm:comps
    sleep 1m
}

function start_lvm() {
    cd $WORKPATH
    echo $(pwd)
    echo "Building LVM Docker Images"
    build_lvm_docker_images
    echo "Starting LVM Services"
    start_lvm_service

}

function start_service() {
    export host_ip=${ip_address}
    export REDIS_HOST=$ip_address
    export REDIS_PORT=6379
    export REDIS_URL="redis://${ip_address}:${REDIS_PORT}"
    export LVM_PORT=5028
    export LVM_ENDPOINT="http://${ip_address}:${LVM_PORT}/v1/lvm"
    export INDEX_NAME="dataprep"
    export TAG="comps"
    service_name="redis-vector-db dataprep-multimodal-redis"
    cd $WORKPATH/comps/dataprep/deployment/docker_compose/
    docker compose up ${service_name} -d

    check_healthy "dataprep-multimodal-redis-server" || exit 1
}

function prepare_data() {
    echo "Prepare Transcript .vtt"
    cd ${LOG_PATH}
    echo $(pwd)
    echo """WEBVTT

00:00:00.000 --> 00:00:03.400
Last year the smoking tire went on the bull run live rally in the

00:00:03.400 --> 00:00:09.760
2010 Ford SBT Raptor. I liked it so much. I bought one. Here it is. We're going back

00:00:09.760 --> 00:00:12.920
to bull run this year of course we'll help from our friends at Black Magic and

00:00:12.920 --> 00:00:19.560
we're so serious about it. We got two Valentine one radar detectors. Oh yeah.

00:00:19.560 --> 00:00:23.760
So we're all set up and the reason we got two is because we're going to be going

00:00:23.760 --> 00:00:29.920
a little bit faster. We got a 2011 Shelby GT500. The 550 horsepower

00:00:29.920 --> 00:00:34.560
all-luminum V8. We are going to be right in the action bringing you guys a video

00:00:34.560 --> 00:00:40.120
every single day live from the bull run rally July 9th to 16th and the only

00:00:40.120 --> 00:00:45.240
place to watch it is on BlackmagicShine.com. We're right here on the smoking

00:00:45.240 --> 00:00:47.440
tire.""" > ${transcript_fn}

    echo "This is an apple." > ${caption_fn}

    echo "Downloading Image (png)"
    wget https://github.com/docarray/docarray/blob/main/tests/toydata/image-data/apple.png?raw=true -O ${image_fn}

    echo "Downloading Image (jpg)"
    wget https://raw.githubusercontent.com/opea-project/GenAIComps/refs/tags/v1.3/comps/animation/src/assets/img/avatar1.jpg -O ${jpg_image_fn}

    echo "Downloading Video"
    wget http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/WeAreGoingOnBullrun.mp4 -O ${video_fn}

    echo "Downloading Audio"
    wget https://github.com/intel/intel-extension-for-transformers/raw/main/intel_extension_for_transformers/neural_chat/assets/audio/sample.wav -O ${audio_fn}

    echo "Downloading PDF"
    wget https://raw.githubusercontent.com/opea-project/GenAIComps/v1.3/comps/third_parties/pathway/src/data/nke-10k-2023.pdf -O ${pdf_fn}
}

function validate_microservice() {
    cd $LOG_PATH

    # test v1/generate_transcripts upload file
    echo "Testing generate_transcripts API"
    URL="http://${ip_address}:$DATAPREP_PORT/v1/dataprep/generate_transcripts"
    HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -F "files=@$video_fn" -F "files=@$audio_fn"  -H 'Content-Type: multipart/form-data' "$URL")
    HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    RESPONSE_BODY=$(echo $HTTP_RESPONSE | sed -e 's/HTTPSTATUS\:.*//g')
    SERVICE_NAME="dataprep - upload - file"

    if [ "$HTTP_STATUS" -ne "200" ]; then
        echo "[ $SERVICE_NAME ] HTTP status is not 200. Received status was $HTTP_STATUS"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] HTTP status is 200. Checking content..."
    fi
    if [[ "$RESPONSE_BODY" != *"Data preparation succeeded"* ]]; then
        echo "[ $SERVICE_NAME ] Content does not match the expected result: $RESPONSE_BODY"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] Content is as expected."
    fi

    # test ingest upload video file
    echo "Testing ingest API with video+transcripts"
    URL="http://${ip_address}:$DATAPREP_PORT/v1/dataprep/ingest"

    HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -F "files=@$video_fn" -F "files=@$transcript_fn" -H 'Content-Type: multipart/form-data' "$URL")
    HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    RESPONSE_BODY=$(echo $HTTP_RESPONSE | sed -e 's/HTTPSTATUS\:.*//g')
    SERVICE_NAME="dataprep - upload - file"

    if [ "$HTTP_STATUS" -ne "200" ]; then
        echo "[ $SERVICE_NAME ] HTTP status is not 200. Received status was $HTTP_STATUS"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] HTTP status is 200. Checking content..."
    fi
    if [[ "$RESPONSE_BODY" != *"Data preparation succeeded"* ]]; then
        echo "[ $SERVICE_NAME ] Content does not match the expected result: $RESPONSE_BODY"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] Content is as expected."
    fi

    # test ingest upload image file with text caption
    echo "Testing ingest API with image+text caption"
    URL="http://${ip_address}:$DATAPREP_PORT/v1/dataprep/ingest"

    HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -F "files=@$image_fn" -F "files=@$caption_fn" -H 'Content-Type: multipart/form-data' "$URL")
    HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    RESPONSE_BODY=$(echo $HTTP_RESPONSE | sed -e 's/HTTPSTATUS\:.*//g')
    SERVICE_NAME="dataprep - upload - file"

    if [ "$HTTP_STATUS" -ne "200" ]; then
        echo "[ $SERVICE_NAME ] HTTP status is not 200. Received status was $HTTP_STATUS"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] HTTP status is 200. Checking content..."
    fi
    if [[ "$RESPONSE_BODY" != *"Data preparation succeeded"* ]]; then
        echo "[ $SERVICE_NAME ] Content does not match the expected result: $RESPONSE_BODY"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] Content is as expected."
    fi

    # test ingest upload image png file with audio caption
    echo "Testing ingest API with png image+audio caption"
    URL="http://${ip_address}:$DATAPREP_PORT/v1/dataprep/ingest"

    HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -F "files=@$image_fn" -F "files=@$audio_fn" -H 'Content-Type: multipart/form-data' "$URL")
    HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    RESPONSE_BODY=$(echo $HTTP_RESPONSE | sed -e 's/HTTPSTATUS\:.*//g')
    SERVICE_NAME="dataprep - upload - file"

    if [ "$HTTP_STATUS" -ne "200" ]; then
        echo "[ $SERVICE_NAME ] HTTP status is not 200. Received status was $HTTP_STATUS"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] HTTP status is 200. Checking content..."
    fi
    if [[ "$RESPONSE_BODY" != *"Data preparation succeeded"* ]]; then
        echo "[ $SERVICE_NAME ] Content does not match the expected result: $RESPONSE_BODY"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] Content is as expected."
    fi

    # test ingest upload image jpg file with audio caption
    echo "Testing ingest API with jpg image+audio caption"
    URL="http://${ip_address}:$DATAPREP_PORT/v1/dataprep/ingest"

    HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -F "files=@$jpg_image_fn" -F "files=@$audio_fn" -H 'Content-Type: multipart/form-data' "$URL")
    HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    RESPONSE_BODY=$(echo $HTTP_RESPONSE | sed -e 's/HTTPSTATUS\:.*//g')
    SERVICE_NAME="dataprep - upload - file"

    if [ "$HTTP_STATUS" -ne "200" ]; then
        echo "[ $SERVICE_NAME ] HTTP status is not 200. Received status was $HTTP_STATUS"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] HTTP status is 200. Checking content..."
    fi
    if [[ "$RESPONSE_BODY" != *"Data preparation succeeded"* ]]; then
        echo "[ $SERVICE_NAME ] Content does not match the expected result: $RESPONSE_BODY"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] Content is as expected."
    fi

    # test ingest with video and image
    echo "Testing ingest API with both video+transcript and image+caption"
    URL="http://${ip_address}:$DATAPREP_PORT/v1/dataprep/ingest"

    HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -F "files=@$image_fn" -F "files=@$caption_fn" -F "files=@$video_fn" -F "files=@$transcript_fn" -H 'Content-Type: multipart/form-data' "$URL")
    HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    RESPONSE_BODY=$(echo $HTTP_RESPONSE | sed -e 's/HTTPSTATUS\:.*//g')
    SERVICE_NAME="dataprep - upload - file"

    if [ "$HTTP_STATUS" -ne "200" ]; then
        echo "[ $SERVICE_NAME ] HTTP status is not 200. Received status was $HTTP_STATUS"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] HTTP status is 200. Checking content..."
    fi
    if [[ "$RESPONSE_BODY" != *"Data preparation succeeded"* ]]; then
        echo "[ $SERVICE_NAME ] Content does not match the expected result: $RESPONSE_BODY"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] Content is as expected."
    fi

    # test ingest with invalid input (.png image with .vtt transcript)
    echo "Testing ingest API with invalid input (.png and .vtt)"
    URL="http://${ip_address}:$DATAPREP_PORT/v1/dataprep/ingest"

    HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -F "files=@$image_fn" -F "files=@$transcript_fn" -H 'Content-Type: multipart/form-data' "$URL")
    HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    RESPONSE_BODY=$(echo $HTTP_RESPONSE | sed -e 's/HTTPSTATUS\:.*//g')
    SERVICE_NAME="dataprep - upload - file"

    if [ "$HTTP_STATUS" -ne "400" ]; then
        echo "[ $SERVICE_NAME ] HTTP status is not 400. Received status was $HTTP_STATUS"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] HTTP status is 400. Checking content..."
    fi
    if [[ "$RESPONSE_BODY" != *"No caption file found for $image_name"* ]]; then
        echo "[ $SERVICE_NAME ] Content does not match the expected result: $RESPONSE_BODY"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] Content is as expected."
    fi

    # test ingest with a PDF file
    echo "Testing ingest API with a PDF file"
    URL="http://${ip_address}:$DATAPREP_PORT/v1/dataprep/ingest"

    HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -F "files=@$pdf_fn" -H 'Content-Type: multipart/form-data' "$URL")
    HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    RESPONSE_BODY=$(echo $HTTP_RESPONSE | sed -e 's/HTTPSTATUS\:.*//g')
    SERVICE_NAME="dataprep - upload - file"

    if [ "$HTTP_STATUS" -ne "200" ]; then
        echo "[ $SERVICE_NAME ] HTTP status is not 200. Received status was $HTTP_STATUS"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] HTTP status is 200. Checking content..."
    fi
    if [[ "$RESPONSE_BODY" != *"Data preparation succeeded"* ]]; then
        echo "[ $SERVICE_NAME ] Content does not match the expected result: $RESPONSE_BODY"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] Content is as expected."
    fi

    # test ingest with a text-only PDF file
    echo "Testing ingest API with a text-only PDF file"
    URL="http://${ip_address}:$DATAPREP_PORT/v1/dataprep/ingest"

    HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -F "files=@$text_ony_pdf_fn" -H 'Content-Type: multipart/form-data' "$URL")
    HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    RESPONSE_BODY=$(echo $HTTP_RESPONSE | sed -e 's/HTTPSTATUS\:.*//g')
    SERVICE_NAME="dataprep - upload - file"

    if [ "$HTTP_STATUS" -ne "200" ]; then
        echo "[ $SERVICE_NAME ] HTTP status is not 200. Received status was $HTTP_STATUS"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] HTTP status is 200. Checking content..."
    fi
    if [[ "$RESPONSE_BODY" != *"Data preparation succeeded"* ]]; then
        echo "[ $SERVICE_NAME ] Content does not match the expected result: $RESPONSE_BODY"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] Content is as expected."
    fi

    # test generate_captions upload video file
    echo "Testing generate_captions API with video"
    URL="http://${ip_address}:$DATAPREP_PORT/v1/dataprep/generate_captions"

    HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -F "files=@$video_fn" -H 'Content-Type: multipart/form-data' "$URL")
    HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    RESPONSE_BODY=$(echo $HTTP_RESPONSE | sed -e 's/HTTPSTATUS\:.*//g')
    SERVICE_NAME="dataprep - upload - file"

    if [ "$HTTP_STATUS" -ne "200" ]; then
        echo "[ $SERVICE_NAME ] HTTP status is not 200. Received status was $HTTP_STATUS"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] HTTP status is 200. Checking content..."
    fi
    if [[ "$RESPONSE_BODY" != *"Data preparation succeeded"* ]]; then
        echo "[ $SERVICE_NAME ] Content does not match the expected result: $RESPONSE_BODY"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] Content is as expected."
    fi

    # test v1/generate_captions upload image file
    echo "Testing generate_captions API with image"
    URL="http://${ip_address}:$DATAPREP_PORT/v1/dataprep/generate_captions"

    HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -F "files=@$image_fn" -H 'Content-Type: multipart/form-data' "$URL")
    HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    RESPONSE_BODY=$(echo $HTTP_RESPONSE | sed -e 's/HTTPSTATUS\:.*//g')
    SERVICE_NAME="dataprep - upload - file"

    if [ "$HTTP_STATUS" -ne "200" ]; then
        echo "[ $SERVICE_NAME ] HTTP status is not 200. Received status was $HTTP_STATUS"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] HTTP status is 200. Checking content..."
    fi
    if [[ "$RESPONSE_BODY" != *"Data preparation succeeded"* ]]; then
        echo "[ $SERVICE_NAME ] Content does not match the expected result: $RESPONSE_BODY"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] Content is as expected."
    fi

    # test /v1/dataprep/get_files
    echo "Testing get_files API"
    URL="http://${ip_address}:$DATAPREP_PORT/v1/dataprep/get"
    HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST "$URL")
    HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    RESPONSE_BODY=$(echo $HTTP_RESPONSE | sed -e 's/HTTPSTATUS\:.*//g')
    SERVICE_NAME="dataprep - get"

    if [ "$HTTP_STATUS" -ne "200" ]; then
        echo "[ $SERVICE_NAME ] HTTP status is not 200. Received status was $HTTP_STATUS"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] HTTP status is 200. Checking content..."
    fi
    if [[ "$RESPONSE_BODY" != *${image_name}* || "$RESPONSE_BODY" != *${video_name}* || "$RESPONSE_BODY" != *${audio_name}* || "$RESPONSE_BODY" != *${pdf_name}* || "$RESPONSE_BODY" != *jpg*  ]]; then
        echo "[ $SERVICE_NAME ] Content does not match the expected result: $RESPONSE_BODY"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] Content is as expected."
    fi

    # test /v1/dataprep/delete
    echo "Testing delete API"
    URL="http://${ip_address}:$DATAPREP_PORT/v1/dataprep/delete"
    HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -d '{"file_path": "dataprep_file.txt"}' -H 'Content-Type: application/json' "$URL")
    HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    RESPONSE_BODY=$(echo $HTTP_RESPONSE | sed -e 's/HTTPSTATUS\:.*//g')
    SERVICE_NAME="dataprep - del"

    # check response status
    if [ "$HTTP_STATUS" -ne "200" ]; then
        echo "[ $SERVICE_NAME ] HTTP status is not 200. Received status was $HTTP_STATUS"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_del.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] HTTP status is 200. Checking content..."
    fi
    # check response body
    if [[ "$RESPONSE_BODY" != *'{"status":true}'* ]]; then
        echo "[ $SERVICE_NAME ] Content does not match the expected result: $RESPONSE_BODY"
        docker logs dataprep-multimodal-redis-server >> ${LOG_PATH}/dataprep_del.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] Content is as expected."
    fi
}

function stop_docker() {
    cid=$(docker ps -aq --filter "name=dataprep-multimodal-redis-server*" --filter "name=redis-vector-*")
    if [[ ! -z "$cid" ]]; then docker stop $cid && docker rm $cid && sleep 1s; fi
    cid=$(docker ps -aq --filter "name=test-comps-lvm*")
    if [[ ! -z "$cid" ]]; then docker stop $cid && docker rm $cid && sleep 1s; fi

}

function delete_data() {
    cd ${LOG_PATH}
    rm -rf ${tmp_dir}
    sleep 1s
}

function main() {

    stop_docker
    build_docker_images
    prepare_data

    start_lvm
    start_service

    validate_microservice
    delete_data
    stop_docker
    echo y | docker system prune

}

main
