.. _install_sandboxes_ai_transcoder_anthropic:

Model selection and transcoding for Anthropic clients
=====================================================

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

This sandbox runs Envoy as an AI gateway for clients of Anthropic's Messages API, such as the Anthropic SDKs: they
send every request to one endpoint, and Envoy sends each to OpenAI, Anthropic or Gemini on Vertex AI in that provider's
own API.

It is the :ref:`model selection and transcoding sandbox <install_sandboxes_ai_transcoder>` with Anthropic's API on the
client side in place of OpenAI's. The :ref:`Gemini clients sandbox <install_sandboxes_ai_transcoder_gemini>` does the
same for Gemini's.

.. image:: /start/sandboxes/_include/ai-transcoder-anthropic/_static/ai-transcoder-anthropic.svg
   :alt: Envoy routes Anthropic requests on their model to OpenAI, Anthropic or Vertex AI, transcoding the requests for OpenAI and Vertex AI

For each request, Envoy:

- reads the request's ``model`` with the :ref:`AI Protocol Manager <config_http_filters_ai_protocol_manager>`,
  whose request info AI filter stores it as the ``envoy.ai.model.request``
  :ref:`filter state object <well_known_filter_state>`, and picks a route on it: ``gpt-*`` models go to OpenAI,
  ``claude-*`` models to Anthropic, and ``gemini-*`` models to Vertex AI. Any other model is answered by Envoy with
  a ``404``.
- converts a request for OpenAI or Vertex AI into the provider's API, and the provider's response (a JSON body or a
  stream of server-sent events) back into Anthropic's, with the AI Protocol Manager's transcoder AI filter. Requests
  for Claude models need no conversion, and reach Anthropic as the client sent them.
- adds the provider's API key, with a :ref:`credential injector <config_http_filters_credential_injector>`, and
  sends it through a single :ref:`dynamic forward proxy <arch_overview_http_dynamic_forward_proxy>` cluster to the
  provider's host, which the route names.

.. warning::

   The AI Protocol Manager and its transcoder are alpha, and their APIs are a work in progress: Envoy logs warnings
   about them at startup.

Step 1: Set your API keys
*************************

Change to the ``ai-transcoder-anthropic`` directory, and export the API key of each provider you want to use.

.. code-block:: console

   $ pwd
   examples/ai-transcoder-anthropic
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

   NAME                              IMAGE                           COMMAND                  SERVICE   CREATED          STATUS                    PORTS
   ai-transcoder-anthropic-proxy-1   ai-transcoder-anthropic-proxy   "/docker-entrypoint.…"   proxy     10 seconds ago   Up 9 seconds (healthy)    0.0.0.0:9901->9901/tcp, 0.0.0.0:10000->10000/tcp

Envoy listens for AI requests on port ``10000``, and serves its admin interface on port ``9901``.

Alternatively, :download:`run-sandbox.sh <_include/ai-transcoder-anthropic/run-sandbox.sh>` does steps 1 and 2: it asks
for each key, without echoing it, and for the Vertex AI project, then builds and starts the sandbox and follows Envoy's
log, which shows where each request went:

.. code-block:: console

   $ ./run-sandbox.sh

.. tip::

   If either port is taken on your machine, set ``PORT_PROXY`` or ``PORT_ADMIN`` before starting the sandbox, and use
   those ports in the steps below.

Step 3: Send the same request to each provider
**********************************************

Send an Anthropic message request to Envoy, asking for an OpenAI model:

.. code-block:: console

   $ curl -s http://localhost:10000/v1/messages \
       -H 'content-type: application/json' \
       -d '{"model": "gpt-4o-mini", "max_tokens": 1024, "messages": [{"role": "user", "content": "In one short sentence, what is Envoy proxy?"}]}' \
       | jq
   {
     "content": [
       {
         "text": "Envoy proxy is an open-source edge and service proxy designed for cloud-native applications, providing features like load balancing, service discovery, and observability.",
         "type": "text"
       }
     ],
     "id": "chatcmpl-EUH9v2D94HFk9I1tkgRIKwYXatyxf",
     "model": "gpt-4o-mini-2024-07-18",
     "role": "assistant",
     "stop_reason": "end_turn",
     "type": "message",
     "usage": {
       "cache_read_input_tokens": 0,
       "input_tokens": 18,
       "output_tokens": 30
     }
   }

OpenAI answered, but the reply is an Anthropic ``message``: Envoy sent the request to OpenAI's Chat Completions API and
converted the answer, including the stop reason and the token usage.

Only the ``model`` changes between providers:

.. code-block:: console

   $ for model in gpt-4o-mini claude-haiku-4-5 gemini-2.5-flash; do
       curl -s http://localhost:10000/v1/messages \
         -H 'content-type: application/json' \
         -d "{\"model\": \"${model}\", \"max_tokens\": 1024, \"messages\": [{\"role\": \"user\", \"content\": \"In one short sentence, what is Envoy proxy?\"}]}" \
         | jq -r '"\(.model): \(.content[0].text)"'
     done
   gpt-4o-mini-2024-07-18: Envoy proxy is an open-source edge and service proxy designed for cloud-native applications, providing advanced features for traffic management, discovery, and observability.
   claude-haiku-4-5-20251001: Envoy is an open-source, high-performance proxy for cloud-native applications.
   gemini-2.5-flash: Envoy is an open-source, high-performance edge and service proxy designed for cloud-native applications.

Step 4: Stream a response
*************************

Ask OpenAI for a stream:

.. code-block:: console

   $ curl -sN http://localhost:10000/v1/messages \
       -H 'content-type: application/json' \
       -d '{"model": "gpt-4o-mini", "max_tokens": 1024, "stream": true, "messages": [{"role": "user", "content": "Reply with just: Hello, Envoy!"}]}'
   event: message_start
   data: {"message":{"content":[],"id":"chatcmpl-EUHAjGkWxwJsJZPJBjo9A3nl6gD0F","model":"gpt-4o-mini-2024-07-18","role":"assistant","stop_reason":null,"stop_sequence":null,"type":"message","usage":{"input_tokens":0,"output_tokens":0}},"type":"message_start"}

   event: content_block_start
   data: {"content_block":{"text":"","type":"text"},"index":0,"type":"content_block_start"}

   event: content_block_delta
   data: {"delta":{"text":"","type":"text_delta"},"index":0,"type":"content_block_delta"}

   event: content_block_delta
   data: {"delta":{"text":"Hello","type":"text_delta"},"index":0,"type":"content_block_delta"}

   event: content_block_delta
   data: {"delta":{"text":",","type":"text_delta"},"index":0,"type":"content_block_delta"}

   event: content_block_delta
   data: {"delta":{"text":" Env","type":"text_delta"},"index":0,"type":"content_block_delta"}

   event: content_block_delta
   data: {"delta":{"text":"oy","type":"text_delta"},"index":0,"type":"content_block_delta"}

   event: content_block_delta
   data: {"delta":{"text":"!","type":"text_delta"},"index":0,"type":"content_block_delta"}

   event: content_block_stop
   data: {"index":0,"type":"content_block_stop"}

   event: message_delta
   data: {"delta":{"stop_reason":"end_turn","stop_sequence":null},"type":"message_delta","usage":{"cache_read_input_tokens":0,"input_tokens":16,"output_tokens":5}}

   event: message_stop
   data: {"type":"message_stop"}

OpenAI streams unnamed ``chat.completion.chunk`` events and ends with ``data: [DONE]``, while Anthropic's clients expect
named events that open and close the message and each of its content blocks. Envoy converted each chunk's text into a
``content_block_delta``, opened the message and its text block with the first chunk, and closed both when OpenAI's
stream ended.

OpenAI only reports a stream's token usage when asked, so Envoy asked for it, and moved it into ``message_delta``,
where Anthropic reports it. Gemini's streams are converted the same way.

Step 5: See where each request went
***********************************

Envoy's access log shows each request's model, and the provider host and path it was sent to:

.. code-block:: console

   $ docker compose logs proxy | grep -- ' -> '
   proxy-1  | gpt-4o-mini -> api.openai.com/v1/chat/completions 200 via_upstream
   proxy-1  | gpt-4o-mini -> api.openai.com/v1/chat/completions 200 via_upstream
   proxy-1  | claude-haiku-4-5 -> api.anthropic.com/v1/messages 200 via_upstream
   proxy-1  | gemini-2.5-flash -> aiplatform.googleapis.com/v1/projects/my-project/locations/global/publishers/google/models/gemini-2.5-flash:generateContent 200 via_upstream
   proxy-1  | gpt-4o-mini -> api.openai.com/v1/chat/completions 200 via_upstream

The log reads the model from the ``envoy.ai.model.request`` filter state object, with
``%FILTER_STATE(envoy.ai.model.request:PLAIN)%``.

Every client sent its request to ``/v1/messages``, which only the Claude request kept. The Gemini request shows the
model moved from the request body into the Vertex AI path.

Step 6: Ask for a model that no provider serves
***********************************************

A model that no route matches never leaves Envoy. It is answered with a ``404``, in Anthropic's error format so that
Anthropic clients can read it:

.. code-block:: console

   $ curl -si http://localhost:10000/v1/messages \
       -H 'content-type: application/json' \
       -d '{"model": "llama-3.1-8b", "max_tokens": 1024, "messages": [{"role": "user", "content": "Hi"}]}'
   HTTP/1.1 404 Not Found
   content-type: application/json
   content-length: 99
   date: Thu, 01 Oct 2026 19:55:12 GMT
   server: envoy

   {"type": "error", "error": {"type": "not_found_error", "message": "No backend serves this model."}}

Step 7: Check the transcoder's statistics
*****************************************

The AI Protocol Manager counts the request bodies it parsed, the models it read, and the payloads it transcoded
(each request, JSON response and streamed event), and the ones it could not:

.. code-block:: console

   $ curl -s "http://localhost:9901/stats?filter=ai_protocol_manager.(request_parsed|request_info.published|transcoder)"
   ai_protocol_manager.request_info.published: 6
   ai_protocol_manager.request_parsed: 10
   ai_protocol_manager.transcoder.failed: 0
   ai_protocol_manager.transcoder.transcoded: 30
   ai_protocol_manager.transcoder.unresolved: 0

The sandbox runs two AI Protocol Managers, which count together: one read the model of all six requests, and the
other parsed the four that OpenAI and Vertex AI served, to transcode them. The Claude request was not parsed a second
time, as it was not transcoded.

Step 8: Use an Anthropic SDK
****************************

Any Anthropic client library can use the sandbox, by pointing its base URL at Envoy. For example, with the
`Anthropic Python library <https://pypi.org/project/anthropic/>`_:

.. code-block:: python

   from anthropic import Anthropic

   # Envoy adds each provider's key, so the client's is not used.
   client = Anthropic(base_url="http://localhost:10000", api_key="unused")

   for model in ["gpt-4o-mini", "claude-haiku-4-5", "gemini-2.5-flash"]:
       print(f"{model}:")
       with client.messages.stream(
           model=model,
           max_tokens=1024,
           messages=[{"role": "user", "content": "Write a haiku about proxies."}],
       ) as stream:
           for text in stream.text_stream:
               print(text, end="", flush=True)
       print("\n")

How the configuration works
***************************

Routing on the model
~~~~~~~~~~~~~~~~~~~~

The model is in the request body, but Envoy picks a route as soon as the request headers arrive, before the body is
read. So every request starts on the last route, ``messages``, the only one that names the endpoint's path. It declares
the request's API for the first AI Protocol Manager, ``read_model``, which therefore parses the body:

.. literalinclude:: _include/ai-transcoder-anthropic/envoy.yaml
   :language: yaml
   :lines: 95-112
   :lineno-start: 95
   :linenos:
   :emphasize-lines: 5, 15-18

``read_model`` runs the request info AI filter, which stores the model as the ``envoy.ai.model.request`` filter state
object. As that filter only reads the request, ``read_model`` forwards the body as it was received. The
``set_filter_state`` filter then clears the route cache, so that the route is picked again, now that the model is
known:

.. literalinclude:: _include/ai-transcoder-anthropic/envoy.yaml
   :language: yaml
   :lines: 113-129
   :lineno-start: 113
   :linenos:

Each provider has a route that matches its models. Here is OpenAI's, in the
:download:`envoy.yaml <_include/ai-transcoder-anthropic/envoy.yaml>` configuration:

.. literalinclude:: _include/ai-transcoder-anthropic/envoy.yaml
   :language: yaml
   :lines: 39-55
   :lineno-start: 39
   :linenos:
   :emphasize-lines: 4-6, 9-10, 13-17

The route:

- matches a model starting with ``gpt-``, with a :ref:`filter state <envoy_v3_api_field_config.route.v3.RouteMatch.filter_state>`
  matcher on ``envoy.ai.model.request``. It needs no path of its own: only a request that ``read_model`` parsed has
  a model, and ``read_model`` parses only the requests of ``messages``.
- names the provider's host, with ``host_rewrite_literal``, and replaces the path with OpenAI's, with
  :ref:`path_rewrite <envoy_v3_api_field_config.route.v3.RouteAction.path_rewrite>`.
- declares the APIs to transcode between, with the AI Protocol Manager's
  :ref:`per-route configuration <envoy_v3_api_msg_extensions.filters.http.ai_protocol_manager.v3.AiProtocolManagerPerRoute>`
  for the second AI Protocol Manager, ``transcode``: the client's request API is Anthropic Messages, and the
  provider's API is OpenAI Chat Completions.
- enables ``openai_key``, the credential injector that adds OpenAI's key.

Anthropic's route declares no APIs for ``transcode``, so that AI Protocol Manager lets its requests through without
parsing them, and Anthropic gets each request, and the client each response, exactly as sent. The route only adds the
``anthropic-version`` header Anthropic requires, if the client left it out:

.. literalinclude:: _include/ai-transcoder-anthropic/envoy.yaml
   :language: yaml
   :lines: 56-72
   :lineno-start: 56
   :linenos:
   :emphasize-lines: 1-2, 13-15

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
     - Anthropic Messages, not transcoded
     - ``api.anthropic.com``
     - ``/v1/messages``
     - ``x-api-key: $ANTHROPIC_API_KEY``
   * - ``gemini-*``
     - Gemini GenerateContent
     - ``aiplatform.googleapis.com``
     - ``/v1/projects/$VERTEX_PROJECT/locations/$VERTEX_LOCATION/publishers/google/models/{model}:generateContent``,
       or ``:streamGenerateContent?alt=sse``
     - ``x-goog-api-key: $VERTEX_API_KEY``

A request whose model no route serves stays on ``messages``, and gets its ``404``.

Transcoding
~~~~~~~~~~~

An AI Protocol Manager reads the APIs a route declares when the request headers reach it. ``read_model`` sees them
before the route is picked on the model, so the transcoding is done by a second AI Protocol Manager, ``transcode``,
placed after ``set_filter_state``: it sees the model's route. It holds the request until its body is parsed, then
runs its AI filters over it:

.. literalinclude:: _include/ai-transcoder-anthropic/envoy.yaml
   :language: yaml
   :lines: 130-146
   :lineno-start: 130
   :linenos:

Every API is translated through one canonical form, OpenAI Chat Completions. The first transcoder converts the
client's Anthropic request into it: the ``system`` prompt becomes the first message, and ``max_tokens`` and
``stop_sequences`` take OpenAI's names. The second converts it into the provider's API. Responses take the reverse
path, one JSON body or one streamed event at a time.

Gemini carries the model, and whether to stream, in the request path rather than the body. The transcoder moves both
into the Gemini API's path, ``/v1beta/models/{model}:generateContent`` or ``:streamGenerateContent?alt=sse``, which the
Vertex AI route then maps onto Vertex AI's:

.. literalinclude:: _include/ai-transcoder-anthropic/envoy.yaml
   :language: yaml
   :lines: 83-88
   :lineno-start: 83
   :linenos:

The regex rewrite keeps the model and the method from the path, but cannot read the environment, so the proxy fills in
``VERTEX_PROJECT`` and ``VERTEX_LOCATION`` as it starts, from the
:download:`docker-compose.yaml <_include/ai-transcoder-anthropic/docker-compose.yaml>` composition:

.. literalinclude:: _include/ai-transcoder-anthropic/docker-compose.yaml
   :language: yaml
   :lines: 10-19
   :lineno-start: 10
   :linenos:

.. note::

   A Vertex AI express mode API key belongs to no project. To use one, change the substitution to
   ``/v1/publishers/google/``.

The AI Protocol Manager cannot read a compressed response, so the virtual host removes the client's
``accept-encoding`` header.

API keys
~~~~~~~~

The keys are :ref:`static secrets <envoy_v3_api_field_config.bootstrap.v3.Bootstrap.StaticResources.secrets>`, read
from the environment as Envoy starts:

.. literalinclude:: _include/ai-transcoder-anthropic/envoy.yaml
   :language: yaml
   :lines: 187-193
   :lineno-start: 187
   :linenos:

A :ref:`credential injector <config_http_filters_credential_injector>` sets one header from one secret, so the router
runs one for each provider, as
:ref:`upstream HTTP filters <envoy_v3_api_field_extensions.filters.http.router.v3.Router.upstream_http_filters>`.
Here is Anthropic's:

.. literalinclude:: _include/ai-transcoder-anthropic/envoy.yaml
   :language: yaml
   :lines: 163-172
   :lineno-start: 163
   :linenos:

OpenAI's sets ``authorization`` with a ``Bearer`` prefix, and Vertex AI's ``x-goog-api-key``. Every injector is
:ref:`disabled <envoy_v3_api_field_extensions.filters.network.http_connection_manager.v3.HttpFilter.disabled>`
unless a route enables it, so each provider is only sent its own key. They are upstream filters because a route can
only enable a filter when the filter is created: the router creates its upstream filters once the model's route is
picked, whereas the HTTP filters are created as the request arrives, on the ``messages`` route.

Anthropic's SDKs send their own key in ``x-api-key``, which the virtual host removes, along with ``authorization`` and
``x-goog-api-key``: no provider is sent a credential the client sent. A request for a provider whose key is empty is
not sent at all, but answered by its injector with a ``401``.

One cluster for every provider
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The requests of every route go to the same :ref:`dynamic forward proxy <arch_overview_http_dynamic_forward_proxy>`
cluster, which looks up the host the route set with ``host_rewrite_literal``, and connects to it over TLS, with the
host as the SNI and as the name the provider's certificate is validated against:

.. literalinclude:: _include/ai-transcoder-anthropic/envoy.yaml
   :language: yaml
   :lines: 195-213
   :lineno-start: 195
   :linenos:

Limitations
~~~~~~~~~~~

- An error response, such as a provider's ``401`` for a key it rejects, is forwarded in the provider's own format:
  the transcoder only converts successful responses. Envoy's own ``401``, for a provider whose key is not set, is plain
  text.
- Not every field has a mapping yet. For OpenAI and Gemini models, a response's tool calls are dropped, and a
  request's images, documents and ``thinking`` are not converted. Claude models, whose requests are not transcoded,
  support them all.
- Only ``/v1/messages`` is routed; other Anthropic endpoints, such as ``/v1/messages/count_tokens``, are not.
- The requests for OpenAI and Gemini models are parsed twice, once by each AI Protocol Manager.

.. seealso::

   :ref:`Model selection and transcoding <install_sandboxes_ai_transcoder>`
      The same gateway, for OpenAI clients.

   :ref:`Model selection and transcoding for Gemini clients <install_sandboxes_ai_transcoder_gemini>`
      The same gateway, for Gemini clients.

   :ref:`AI Protocol Manager <config_http_filters_ai_protocol_manager>`
      Learn more about the AI Protocol Manager filter and its AI filters.

   :ref:`Transcoder API <envoy_v3_api_msg_extensions.http.ai_filters.transcoder.v3.Transcoder>`
      The transcoder AI filter's configuration.

   :ref:`Credential injector <config_http_filters_credential_injector>`
      Learn more about the credential injector filter.

   :ref:`Dynamic forward proxy <arch_overview_http_dynamic_forward_proxy>`
      Learn more about Envoy's dynamic forward proxy.
