#!/bin/bash -e

export NAME=ai-transcoder-anthropic
export PORT_PROXY="${AI_TRANSCODER_ANTHROPIC_PORT_PROXY:-12920}"
export PORT_ADMIN="${AI_TRANSCODER_ANTHROPIC_PORT_ADMIN:-12921}"

# shellcheck source=verify-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../verify-common.sh"

message () {
    local model="$1" stream="${2:-false}"
    _curl -X POST "http://localhost:${PORT_PROXY}/v1/messages" \
          -H 'content-type: application/json' \
          -H 'anthropic-version: 2023-06-01' \
          -d "{\"model\": \"${model}\", \"max_tokens\": 1024, \"stream\": ${stream}, \"messages\": [{\"role\": \"user\", \"content\": \"In one short sentence, what is Envoy proxy?\"}]}"
}

# A provider is only sent requests when the variables it needs, its API key first, are set.
test_provider () {
    local required="$1" model="$2" unary_upstream="$3" stream_upstream="$4" key stream var
    key="${required%% *}"
    if [[ -z "${!key}" ]]; then
        run_log "Answer ${model} with a local 401, as ${key} is not set"
        message "$model" | grep -Fx 'Failed to inject credential.'
        wait_for 10 bash -c "${DOCKER_COMPOSE[*]} logs proxy | grep -F '${model} -> ${unary_upstream} 401 failed_to_inject_credential'"
        return
    fi
    for var in $required; do
        if [[ -z "${!var}" ]]; then
            run_log "Skip ${model}: set ${var} to send it to its provider"
            return
        fi
    done

    run_log "Send a message to ${model}: the reply is an Anthropic message"
    message "$model" | jq -e '.type == "message" and .role == "assistant" and (.content[0].text | length > 0)'

    run_log "Stream from ${model}: Anthropic's events, from message_start to message_stop"
    stream="$(message "$model" true | tr -d '\r')"
    sed -n 's/^data: //p' <<< "$stream" \
        | jq -e -s '.[0].type == "message_start" and .[-1].type == "message_stop"
                    and any(.type == "content_block_delta" and (.delta.text | length > 0))'
    diff <(sed -n 's/^event: //p' <<< "$stream") \
         <(sed -n 's/^data: //p' <<< "$stream" | jq -r .type)

    run_log "Check the access log: ${model} went to ${unary_upstream}, and to ${stream_upstream} when streaming"
    wait_for 10 bash -c "${DOCKER_COMPOSE[*]} logs proxy | grep -F '${model} -> ${unary_upstream} 200'"
    wait_for 10 bash -c "${DOCKER_COMPOSE[*]} logs proxy | grep -F '${model} -> ${stream_upstream} 200'"
}

run_log "Answer a model that no route serves with a local Anthropic error"
message llama-3.1-8b | jq -e '.type == "error" and .error.type == "not_found_error"'

test_provider OPENAI_API_KEY gpt-4o-mini \
    api.openai.com/v1/chat/completions \
    api.openai.com/v1/chat/completions
test_provider ANTHROPIC_API_KEY claude-haiku-4-5 \
    api.anthropic.com/v1/messages \
    api.anthropic.com/v1/messages
VERTEX_MODEL_PATH="aiplatform.googleapis.com/v1/projects/${VERTEX_PROJECT}/locations/${VERTEX_LOCATION:-global}/publishers/google/models/gemini-2.5-flash"
test_provider "VERTEX_API_KEY VERTEX_PROJECT" gemini-2.5-flash \
    "${VERTEX_MODEL_PATH}:generateContent" \
    "${VERTEX_MODEL_PATH}:streamGenerateContent?alt=sse"

run_log "Check that no request or response failed to transcode"
responds_with \
    "ai_protocol_manager.transcoder.failed: 0" \
    "http://localhost:${PORT_ADMIN}/stats?filter=transcoder"
