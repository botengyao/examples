#!/bin/bash -e

export NAME=ai-transcoder-gemini
export PORT_PROXY="${AI_TRANSCODER_GEMINI_PORT_PROXY:-12910}"
export PORT_ADMIN="${AI_TRANSCODER_GEMINI_PORT_ADMIN:-12911}"

# shellcheck source=verify-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../verify-common.sh"

UNARY=generateContent
STREAM='streamGenerateContent?alt=sse'

generate () {
    local model="$1" method="${2:-$UNARY}"
    _curl -X POST "http://localhost:${PORT_PROXY}/v1beta/models/${model}:${method}" \
          -H 'content-type: application/json' \
          -d '{"contents": [{"role": "user", "parts": [{"text": "In one short sentence, what is Envoy proxy?"}]}]}'
}

# A provider is only sent requests when the variables it needs, its API key first, are set.
test_provider () {
    local required="$1" model="$2" unary_upstream="$3" stream_upstream="$4" key stream var
    key="${required%% *}"
    if [[ -z "${!key}" ]]; then
        run_log "Answer ${model} with a local 401, as ${key} is not set"
        generate "$model" | grep -Fx 'Failed to inject credential.'
        wait_for 10 bash -c "${DOCKER_COMPOSE[*]} logs proxy | grep -F '/${model}:${UNARY} -> ${unary_upstream} 401 failed_to_inject_credential'"
        return
    fi
    for var in $required; do
        if [[ -z "${!var}" ]]; then
            run_log "Skip ${model}: set ${var} to send it to its provider"
            return
        fi
    done

    run_log "Generate content with ${model}: the reply is a Gemini GenerateContentResponse"
    generate "$model" | jq -e '.candidates[0].content.parts[0].text | length > 0'

    run_log "Stream from ${model}: Gemini GenerateContentResponse chunks, with no [DONE] event"
    stream="$(generate "$model" "$STREAM" | tr -d '\r')"
    sed -n 's/^data: //p' <<< "$stream" \
        | jq -e -s 'any(.[].candidates[]?.content.parts[]?.text; length > 0)'

    run_log "Check the access log: ${model} went to ${unary_upstream}, and to ${stream_upstream} when streaming"
    wait_for 10 bash -c "${DOCKER_COMPOSE[*]} logs proxy | grep -F '/${model}:${UNARY} -> ${unary_upstream} 200'"
    wait_for 10 bash -c "${DOCKER_COMPOSE[*]} logs proxy | grep -F '/${model}:streamGenerateContent' | grep -F ' -> ${stream_upstream} 200'"
}

run_log "Answer a model that no route serves with a local Gemini error"
generate llama-3.1-8b | jq -e '.error.status == "NOT_FOUND"'

test_provider OPENAI_API_KEY gpt-4o-mini \
    api.openai.com/v1/chat/completions \
    api.openai.com/v1/chat/completions
test_provider ANTHROPIC_API_KEY claude-haiku-4-5 \
    api.anthropic.com/v1/messages \
    api.anthropic.com/v1/messages
VERTEX_MODEL_PATH="aiplatform.googleapis.com/v1/projects/${VERTEX_PROJECT}/locations/${VERTEX_LOCATION:-global}/publishers/google/models/gemini-2.5-flash"
test_provider "VERTEX_API_KEY VERTEX_PROJECT" gemini-2.5-flash \
    "${VERTEX_MODEL_PATH}:${UNARY}" \
    "${VERTEX_MODEL_PATH}:${STREAM}"

run_log "Check that no request or response failed to transcode"
responds_with \
    "ai_protocol_manager.transcoder.failed: 0" \
    "http://localhost:${PORT_ADMIN}/stats?filter=transcoder"
