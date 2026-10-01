.. _install_sandboxes_ai_transcoder_gemini:

Model selection and transcoding for Gemini clients
==================================================

.. sidebar:: Requirements

   .. include:: _include/docker-env-setup-link.rst

   :ref:`curl <start_sandboxes_setup_curl>`
        Used to make HTTP requests.

   :ref:`jq <start_sandboxes_setup_jq>`
        Parse JSON output from the proxy.

   API keys
        For each provider you want to try: `OpenAI <https://platform.openai.com/api-keys>`_,
        `Anthropic <https://console.anthropic.com/settings/keys>`_ and
        `Vertex AI <https://cloud.google.com/vertex-ai/generative-ai/docs/start/api-keys>`_.

This sandbox runs Envoy as an AI gateway for clients of the Gemini API, such as the Google Gen AI SDKs: they send
every request to Envoy as they would to Gemini, and Envoy sends each to OpenAI, Anthropic or Gemini on Vertex AI in
that provider's own API.

It is the :ref:`model selection and transcoding sandbox <install_sandboxes_ai_transcoder>` with Gemini's API on the
client side in place of OpenAI's. The :ref:`Anthropic clients sandbox <install_sandboxes_ai_transcoder_anthropic>` does
the same for Anthropic's.

.. image:: /start/sandboxes/_include/ai-transcoder-gemini/_static/ai-transcoder-gemini.svg
   :alt: Envoy routes Gemini requests on the model in their path to OpenAI, Anthropic or Vertex AI, transcoding the requests for OpenAI and Anthropic

Unlike OpenAI's and Anthropic's APIs, the Gemini API names the model in the request path,
``/v1beta/models/{model}:generateContent``. So for each request, Envoy:

- picks a route on the model in the path, as soon as the request headers arrive: ``gpt-*`` models go to OpenAI,
  ``claude-*`` models to Anthropic, and ``gemini-*`` models to Vertex AI. Any other model is answered by Envoy with a
  ``404``.
- converts a request for OpenAI or Anthropic into the provider's API, and the provider's response (a JSON body or a
  stream of server-sent events) back into Gemini's, with the
  :ref:`AI Protocol Manager <config_http_filters_ai_protocol_manager>`'s transcoder AI filter. Requests for Gemini
  models need no conversion, and reach Vertex AI as the client sent them.
- adds the provider's API key, with a :ref:`credential injector <config_http_filters_credential_injector>`, and
  sends it through a single :ref:`dynamic forward proxy <arch_overview_http_dynamic_forward_proxy>` cluster to the
  provider's host, which the route names.

.. warning::

   The AI Protocol Manager and its transcoder are alpha, and their APIs are a work in progress: Envoy logs warnings
   about them at startup.

Step 1: Set your API keys
*************************

Change to the ``ai-transcoder-gemini`` directory, and export the API key of each provider you want to use.

.. code-block:: console

   $ pwd
   examples/ai-transcoder-gemini
   $ export OPENAI_API_KEY=sk-...
   $ export ANTHROPIC_API_KEY=sk-ant-...
   $ export VERTEX_API_KEY=...

For Vertex AI, also export the Google Cloud project the key belongs to, and the location to call, ``global`` by
default:

.. code-block:: console

   $ export VERTEX_PROJECT=my-project
   $ export VERTEX_LOCATION=global

The keys are passed to the Envoy container as environment variables, which Envoy loads as secrets and adds to the
requests it sends to each provider: clients do not need them. Envoy answers a request for a provider whose key is not
set with a ``401`` itself, without sending it.

Step 2: Start the sandbox
*************************

Build and start the proxy.

.. code-block:: console

   $ docker compose pull
   $ docker compose up --build -d
   $ docker compose ps

   NAME                           IMAGE                        COMMAND                  SERVICE   CREATED          STATUS                    PORTS
   ai-transcoder-gemini-proxy-1   ai-transcoder-gemini-proxy   "/docker-entrypoint.…"   proxy     10 seconds ago   Up 9 seconds (healthy)    0.0.0.0:9901->9901/tcp, 0.0.0.0:10000->10000/tcp

Envoy listens for AI requests on port ``10000``, and serves its admin interface on port ``9901``.

Alternatively, :download:`run-sandbox.sh <_include/ai-transcoder-gemini/run-sandbox.sh>` does steps 1 and 2: it asks
for each key, without echoing it, and for the Vertex AI project, then builds and starts the sandbox and follows Envoy's
log, which shows where each request went:

.. code-block:: console

   $ ./run-sandbox.sh

.. tip::

   If either port is taken on your machine, set ``PORT_PROXY`` or ``PORT_ADMIN`` before starting the sandbox, and use
   those ports in the steps below.

Step 3: Send the same request to each provider
**********************************************

Send a Gemini ``generateContent`` request to Envoy, asking for an OpenAI model:

.. code-block:: console

   $ curl -s http://localhost:10000/v1beta/models/gpt-4o-mini:generateContent \
       -H 'content-type: application/json' \
       -d '{"contents": [{"role": "user", "parts": [{"text": "In one short sentence, what is Envoy proxy?"}]}]}' \
       | jq
   {
     "candidates": [
       {
         "content": {
           "parts": [
             {
               "text": "Envoy proxy is an open-source edge and service proxy designed for cloud-native applications, providing features like load balancing, service discovery, and observability."
             }
           ],
           "role": "model"
         },
         "finishReason": "STOP",
         "index": 0
       }
     ],
     "modelVersion": "gpt-4o-mini-2024-07-18",
     "usageMetadata": {
       "cachedContentTokenCount": 0,
       "candidatesTokenCount": 30,
       "promptTokenCount": 18,
       "thoughtsTokenCount": 0,
       "totalTokenCount": 48
     }
   }

OpenAI answered, but the reply is a Gemini ``GenerateContentResponse``: Envoy sent the request to OpenAI's Chat
Completions API and converted the answer, including the finish reason and the token usage.

Only the model in the path changes between providers:

.. code-block:: console

   $ for model in gpt-4o-mini claude-haiku-4-5 gemini-2.5-flash; do
       curl -s "http://localhost:10000/v1beta/models/${model}:generateContent" \
         -H 'content-type: application/json' \
         -d '{"contents": [{"role": "user", "parts": [{"text": "In one short sentence, what is Envoy proxy?"}]}]}' \
         | jq -r '"\(.modelVersion): \(.candidates[0].content.parts[0].text)"'
     done
   gpt-4o-mini-2024-07-18: Envoy proxy is an open-source edge and service proxy designed for cloud-native applications, providing advanced traffic management, load balancing, and observability features.
   claude-haiku-4-5-20251001: Envoy is an open-source, high-performance proxy for cloud-native applications.
   gemini-2.5-flash: Envoy is an open-source, high-performance edge and service proxy designed for cloud-native applications.

Step 4: Stream a response
*************************

Ask OpenAI for a stream, with Gemini's ``streamGenerateContent`` method:

.. code-block:: console

   $ curl -sN "http://localhost:10000/v1beta/models/gpt-4o-mini:streamGenerateContent?alt=sse" \
       -H 'content-type: application/json' \
       -d '{"contents": [{"role": "user", "parts": [{"text": "Reply with just: Hello, Envoy!"}]}]}'
   data: {"candidates":[{"content":{"parts":[{"text":""}],"role":"model"},"index":0}],"modelVersion":"gpt-4o-mini-2024-07-18"}

   data: {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"},"index":0}],"modelVersion":"gpt-4o-mini-2024-07-18"}

   data: {"candidates":[{"content":{"parts":[{"text":","}],"role":"model"},"index":0}],"modelVersion":"gpt-4o-mini-2024-07-18"}

   data: {"candidates":[{"content":{"parts":[{"text":" Env"}],"role":"model"},"index":0}],"modelVersion":"gpt-4o-mini-2024-07-18"}

   data: {"candidates":[{"content":{"parts":[{"text":"oy"}],"role":"model"},"index":0}],"modelVersion":"gpt-4o-mini-2024-07-18"}

   data: {"candidates":[{"content":{"parts":[{"text":"!"}],"role":"model"},"index":0}],"modelVersion":"gpt-4o-mini-2024-07-18"}

   data: {"candidates":[{"content":{"parts":[{"text":""}],"role":"model"},"finishReason":"STOP","index":0}],"modelVersion":"gpt-4o-mini-2024-07-18"}

   data: {"modelVersion":"gpt-4o-mini-2024-07-18","usageMetadata":{"cachedContentTokenCount":0,"candidatesTokenCount":5,"promptTokenCount":16,"thoughtsTokenCount":0,"totalTokenCount":21}}

The method in the path asked for a stream, so Envoy sent OpenAI ``"stream": true``, and converted each
``chat.completion.chunk`` of OpenAI's stream into a Gemini response chunk.

OpenAI ends its stream with ``data: [DONE]``, which Gemini clients do not expect, so Envoy left it out. OpenAI also
only reports a stream's token usage when asked, so Envoy asked for it: it arrives in a chunk of its own, as
``usageMetadata``. Anthropic's named events, from ``message_start`` to ``message_stop``, are converted the same way.

Step 5: See where each request went
***********************************

Envoy's access log shows the path each client called, and the provider host and path Envoy sent the request to:

.. code-block:: console

   $ docker compose logs proxy | grep -- ' -> '
   proxy-1  | /v1beta/models/gpt-4o-mini:generateContent -> api.openai.com/v1/chat/completions 200 via_upstream
   proxy-1  | /v1beta/models/gpt-4o-mini:generateContent -> api.openai.com/v1/chat/completions 200 via_upstream
   proxy-1  | /v1beta/models/claude-haiku-4-5:generateContent -> api.anthropic.com/v1/messages 200 via_upstream
   proxy-1  | /v1beta/models/gemini-2.5-flash:generateContent -> aiplatform.googleapis.com/v1/projects/my-project/locations/global/publishers/google/models/gemini-2.5-flash:generateContent 200 via_upstream
   proxy-1  | /v1beta/models/gpt-4o-mini:streamGenerateContent -> api.openai.com/v1/chat/completions 200 via_upstream

The router keeps the path it rewrote in the
:ref:`x-envoy-original-path <config_http_filters_router_x-envoy-original-path>` header, which the log reads with
``%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%``.

The paths of the OpenAI and Anthropic requests no longer name the model: their APIs expect it in the request body,
where Envoy moved it. The Gemini request kept its path, nested under the Vertex AI project and location.

Step 6: Ask for a model that no provider serves
***********************************************

A model that no route matches never leaves Envoy. It is answered with a ``404``, in Gemini's error format so that
Gemini clients can read it:

.. code-block:: console

   $ curl -si http://localhost:10000/v1beta/models/llama-3.1-8b:generateContent \
       -H 'content-type: application/json' \
       -d '{"contents": [{"role": "user", "parts": [{"text": "Hi"}]}]}'
   HTTP/1.1 404 Not Found
   content-type: application/json
   content-length: 91
   date: Thu, 01 Oct 2026 19:55:32 GMT
   server: envoy
   connection: close

   {"error": {"code": 404, "message": "No backend serves this model.", "status": "NOT_FOUND"}}

Step 7: Check the transcoder's statistics
*****************************************

The AI Protocol Manager counts the request bodies it parsed, and the payloads it transcoded (each request, JSON
response and streamed event), and the ones it could not:

.. code-block:: console

   $ curl -s "http://localhost:9901/stats?filter=ai_protocol_manager.(request_parsed|transcoder)"
   ai_protocol_manager.request_parsed: 4
   ai_protocol_manager.transcoder.failed: 0
   ai_protocol_manager.transcoder.transcoded: 31
   ai_protocol_manager.transcoder.unresolved: 0

Of the six requests, the AI Protocol Manager only parsed the four it transcoded, for OpenAI and Anthropic: the Gemini
request went to Vertex AI as it was received, and Envoy answered the last one itself.

Step 8: Use a Google Gen AI SDK
*******************************

Any Gemini API client library can use the sandbox, by pointing its base URL at Envoy. For example, with the
`Google Gen AI Python SDK <https://pypi.org/project/google-genai/>`_:

.. code-block:: python

   from google import genai
   from google.genai import types

   # Envoy adds each provider's key, so the client's is not used.
   client = genai.Client(
       api_key="unused",
       http_options=types.HttpOptions(base_url="http://localhost:10000"),
   )

   for model in ["gpt-4o-mini", "claude-haiku-4-5", "gemini-2.5-flash"]:
       print(f"{model}:")
       for chunk in client.models.generate_content_stream(
           model=model,
           contents="Write a haiku about proxies.",
       ):
           print(chunk.text or "", end="", flush=True)
       print("\n")

How the configuration works
***************************

Routing on the model
~~~~~~~~~~~~~~~~~~~~

The model is in the request path, so Envoy can pick a provider's route as soon as the request headers arrive. Each
provider has a route that matches its models. Here is OpenAI's, in the
:download:`envoy.yaml <_include/ai-transcoder-gemini/envoy.yaml>` configuration:

.. literalinclude:: _include/ai-transcoder-gemini/envoy.yaml
   :language: yaml
   :lines: 37-56
   :lineno-start: 37
   :linenos:
   :emphasize-lines: 5, 8-9, 12-20

The route:

- matches a model starting with ``gpt-``, called with either of Gemini's methods, ``generateContent`` or
  ``streamGenerateContent``, with a regex on the path.
- names the provider's host, with ``host_rewrite_literal``, and replaces the path with OpenAI's, with
  :ref:`path_rewrite <envoy_v3_api_field_config.route.v3.RouteAction.path_rewrite>`.
- declares the APIs to transcode between, with the AI Protocol Manager's
  :ref:`per-route configuration <envoy_v3_api_msg_extensions.filters.http.ai_protocol_manager.v3.AiProtocolManagerPerRoute>`:
  the client's request API is Gemini GenerateContent, and the provider's API is OpenAI Chat Completions.
- enables ``openai_key``, the credential injector that adds OpenAI's key, and removes the ``alt`` query parameter,
  which only Gemini's streaming method takes.

Anthropic's route differs in its host, its path, ``/v1/messages``, and its provider API, Anthropic Messages. It also
adds the ``anthropic-version`` header Anthropic requires.

Vertex AI's route declares no APIs to transcode between, so the AI Protocol Manager lets its requests through without
parsing them, and Vertex AI gets each request, and the client each response, exactly as sent. The route only nests the
model under Vertex AI's project and location:

.. literalinclude:: _include/ai-transcoder-gemini/envoy.yaml
   :language: yaml
   :lines: 78-93
   :lineno-start: 78
   :linenos:
   :emphasize-lines: 1-2, 12-14

The routes only differ in these settings:

.. list-table::
   :header-rows: 1

   * - Model
     - Provider API
     - Host
     - Path
     - API key header
   * - ``gpt-*``
     - OpenAI Chat Completions
     - ``api.openai.com``
     - ``/v1/chat/completions``
     - ``authorization: Bearer $OPENAI_API_KEY``
   * - ``claude-*``
     - Anthropic Messages
     - ``api.anthropic.com``
     - ``/v1/messages``
     - ``x-api-key: $ANTHROPIC_API_KEY``, and ``anthropic-version``
   * - ``gemini-*``
     - Gemini GenerateContent, not transcoded
     - ``aiplatform.googleapis.com``
     - ``/v1/projects/$VERTEX_PROJECT/locations/$VERTEX_LOCATION/publishers/google/models/{model}:generateContent``,
       or ``:streamGenerateContent?alt=sse``
     - ``x-goog-api-key: $VERTEX_API_KEY``

A request for any other model falls through to the last route, ``generate_content``, which answers it with the ``404``.

The regex rewrite keeps the model and the method from the path, but cannot read the environment, so the proxy fills in
``VERTEX_PROJECT`` and ``VERTEX_LOCATION`` as it starts, from the
:download:`docker-compose.yaml <_include/ai-transcoder-gemini/docker-compose.yaml>` composition:

.. literalinclude:: _include/ai-transcoder-gemini/docker-compose.yaml
   :language: yaml
   :lines: 10-19
   :lineno-start: 10
   :linenos:

.. note::

   A Vertex AI express mode API key belongs to no project. To use one, change the substitution to
   ``/v1/publishers/google/``.

Transcoding
~~~~~~~~~~~

The route is known from the request headers, so one AI Protocol Manager, ``transcode``, sees the APIs the route
declares. It holds the request until its body is parsed, then runs its AI filters over it:

.. literalinclude:: _include/ai-transcoder-gemini/envoy.yaml
   :language: yaml
   :lines: 114-130
   :lineno-start: 114
   :linenos:

Every API is translated through one canonical form, OpenAI Chat Completions. The first transcoder converts the
client's Gemini request into it: it reads the model, and whether to stream, from the path, turns ``contents`` into
``messages`` and ``systemInstruction`` into a system message, and lifts ``generationConfig``'s settings to the top
level. The second converts it into the provider's API. Responses take the reverse path, one JSON body or one streamed
event at a time.

The AI Protocol Manager cannot read a compressed response, so the virtual host removes the client's
``accept-encoding`` header.

API keys
~~~~~~~~

The keys are :ref:`static secrets <envoy_v3_api_field_config.bootstrap.v3.Bootstrap.StaticResources.secrets>`, read
from the environment as Envoy starts:

.. literalinclude:: _include/ai-transcoder-gemini/envoy.yaml
   :language: yaml
   :lines: 171-177
   :lineno-start: 171
   :linenos:

A :ref:`credential injector <config_http_filters_credential_injector>` sets one header from one secret, so the router
runs one for each provider, as
:ref:`upstream HTTP filters <envoy_v3_api_field_extensions.filters.http.router.v3.Router.upstream_http_filters>`.
Here is Vertex AI's:

.. literalinclude:: _include/ai-transcoder-gemini/envoy.yaml
   :language: yaml
   :lines: 157-166
   :lineno-start: 157
   :linenos:

OpenAI's sets ``authorization`` with a ``Bearer`` prefix, and Anthropic's ``x-api-key``. Every injector is
:ref:`disabled <envoy_v3_api_field_extensions.filters.network.http_connection_manager.v3.HttpFilter.disabled>`
unless a route enables it, so each provider is only sent its own key.

No provider is sent a credential the client sent. The Google Gen AI SDKs send their key in ``x-goog-api-key``, which
the virtual host removes, along with ``authorization`` and ``x-api-key``. Other Gemini API clients send it as the
``key`` query parameter, which a :ref:`header mutation <config_http_filters_header_mutation>` filter removes:

.. literalinclude:: _include/ai-transcoder-gemini/envoy.yaml
   :language: yaml
   :lines: 107-113
   :lineno-start: 107
   :linenos:

A request for a provider whose key is empty is not sent at all, but answered by its injector with a ``401``.

One cluster for every provider
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The requests of every route go to the same :ref:`dynamic forward proxy <arch_overview_http_dynamic_forward_proxy>`
cluster, which looks up the host the route set with ``host_rewrite_literal``, and connects to it over TLS, with the
host as the SNI and as the name the provider's certificate is validated against:

.. literalinclude:: _include/ai-transcoder-gemini/envoy.yaml
   :language: yaml
   :lines: 179-197
   :lineno-start: 179
   :linenos:

Limitations
~~~~~~~~~~~

- An error response, such as a provider's ``401`` for a key it rejects, is forwarded in the provider's own format:
  the transcoder only converts successful responses. Envoy's own ``401``, for a provider whose key is not set, is plain
  text.
- Not every field has a mapping yet. For OpenAI and Anthropic models, only text parts are converted, and a request
  with any other part, such as an image or a function call, is rejected with a ``400``. Tools are not converted
  either, and of ``generationConfig``, only ``maxOutputTokens``, ``temperature``, ``topP``, ``stopSequences`` and
  ``seed`` are. Gemini models, whose requests are not transcoded, support them all.
- Only ``generateContent`` and ``streamGenerateContent`` are routed; other Gemini API methods, such as
  ``countTokens``, are not.

.. seealso::

   :ref:`Model selection and transcoding <install_sandboxes_ai_transcoder>`
      The same gateway, for OpenAI clients.

   :ref:`Model selection and transcoding for Anthropic clients <install_sandboxes_ai_transcoder_anthropic>`
      The same gateway, for Anthropic clients.

   :ref:`AI Protocol Manager <config_http_filters_ai_protocol_manager>`
      Learn more about the AI Protocol Manager filter and its AI filters.

   :ref:`Transcoder API <envoy_v3_api_msg_extensions.http.ai_filters.transcoder.v3.Transcoder>`
      The transcoder AI filter's configuration.

   :ref:`Credential injector <config_http_filters_credential_injector>`
      Learn more about the credential injector filter.

   :ref:`Dynamic forward proxy <arch_overview_http_dynamic_forward_proxy>`
      Learn more about Envoy's dynamic forward proxy.
