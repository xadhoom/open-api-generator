defmodule OpenAPI.Processor do
  @moduledoc """
  Phase two of code generation

  The **process** phase begins with a decoded API description from the **read** phase. It may
  represent the contents of one or more files, including one or more root descriptions if
  supplemental files were used.

  This library takes an "operation first" mindset when processing the description. Schemas are
  ignored until they are referenced by an operation (ex. as a response body). It is the job of
  this phase to observe all of the operations and their referenced schemas, process them into
  data structures more relevant to code generation, and prepare the data for rendering.

  ## Customization

  At several points during code generation, it may be useful to customize the behaviour of the
  processor. For this purpose, this module is a Behaviour with most of its critical logic
  implemented as optional callbacks.
  """
  alias OpenAPI.Processor.Operation
  alias OpenAPI.Processor.Operation.Param
  alias OpenAPI.Processor.State
  alias OpenAPI.Spec
  alias OpenAPI.Spec.Path.Operation, as: OperationSpec
  alias OpenAPI.Spec.Response, as: ResponseSpec
  alias OpenAPI.Spec.Schema.Media, as: MediaSpec

  @doc """
  Run the processing phase of the code generator

  This functions is used by the main `OpenAPI` module. It is unlikely that you will call this
  function directly, unless you are reimplementing one of the core functions. If this happens,
  please share your use-case with the maintainers; a plugin might be warranted.
  """
  @spec run(OpenAPI.State.t()) :: OpenAPI.State.t()
  def run(state) do
    state
    |> State.new()
    |> collect_operations_and_schemas()

    # |> IO.inspect(pretty: true, syntax_colors: IO.ANSI.syntax_colors())
    state
  end

  #
  # Integration
  #

  defmacro __using__(_opts) do
    quote do
      defdelegate include_operation?(state, operation), to: OpenAPI.Processor
      defdelegate include_schema?(state, schema), to: OpenAPI.Processor
      defdelegate operation_docstring(operation_spec, params), to: OpenAPI.Processor
      defdelegate operation_function_name(operation_spec), to: OpenAPI.Processor
      defdelegate operation_request_body(operation_spec), to: OpenAPI.Processor
      defdelegate operation_request_method(operation_spec), to: OpenAPI.Processor

      defoverridable include_operation?: 2,
                     include_schema?: 2,
                     operation_docstring: 2,
                     operation_function_name: 1,
                     operation_request_body: 1,
                     operation_request_method: 1
    end
  end

  #
  # Callbacks
  #

  @optional_callbacks include_operation?: 2,
                      include_schema?: 2,
                      operation_docstring: 2,
                      operation_function_name: 1,
                      operation_request_body: 1,
                      operation_request_method: 1

  @doc """
  Whether to render the given operation in the generated code

  If this function returns `false`, the operation will not appear in the generated code.

  See `OpenAPI.Processor.include_operation?/2` for the default implementation.
  """
  @callback include_operation?(State.t(), OperationSpec.t()) :: boolean

  @doc """
  Whether to render the given schema in the generated code

  If this function returns `false`, the schema will not appear in the generated code (unless it
  passes this test when presented in another context) and a plain `map` will be used as its type.

  See `OpenAPI.Processor.include_schema?/2` for the default implementation.
  """
  @callback include_schema?(State.t(), OpenAPI.Spec.Schema.t()) :: boolean

  @doc """
  Construct a docstring for the given operation

  This function accepts the operation spec as well as a list of the **processed** query params
  associated with the operation.

  See `OpenAPI.Processor.Operation.docstring/2` for the default implementation.
  """
  @callback operation_docstring(OperationSpec.t(), [Param.t()]) :: String.t()

  @doc """
  Choose the name of the client function for the given operation

  This function accepts the operation spec and chooses a name for the client function that will
  be generated. The name must be unique within its module (see `c:operation_module_name/1`).

  See `OpenAPI.Processor.Naming.operation_function/1` for the default implementation.
  """
  @callback operation_function_name(OperationSpec.t()) :: atom

  @doc """
  Collect a list of request content types and their associated schemas

  This function accepts the operation spec and returns a list of tuples containing the content
  type (ex. "application/json") and the schema associated with that type.

  See `OpenAPI.Processor.Operation.request_body/1` for the default implementation.
  """
  @callback operation_request_body(OperationSpec.t()) :: Operation.request_body()

  @doc """
  Choose and cast the request method for the given operation

  This function accepts the operation spec and must return the (lowercase) atom representing the
  HTTP method.

  See `OpenAPI.Processor.Operation.request_method/1` for the default implementation.
  """
  @callback operation_request_method(OperationSpec.t()) :: Operation.method()

  #
  # Default Implementations
  #

  @spec include_operation?(State.t(), OperationSpec.t()) :: boolean
  def include_operation?(state, operation) do
    not OpenAPI.Processor.Ignore.ignored?(state, operation)
  end

  @spec include_schema?(State.t(), OpenAPI.Spec.Schema.t()) :: boolean
  def include_schema?(state, schema) do
    not OpenAPI.Processor.Ignore.ignored?(state, schema)
  end

  defdelegate operation_docstring(operation_spec, params),
    to: OpenAPI.Processor.Operation,
    as: :docstring

  defdelegate operation_function_name(operation_spec),
    to: OpenAPI.Processor.Naming,
    as: :operation_function

  defdelegate operation_request_body(operation_spec),
    to: OpenAPI.Processor.Operation,
    as: :request_body

  defdelegate operation_request_method(operation_spec),
    to: OpenAPI.Processor.Operation,
    as: :request_method

  #
  # Helpers
  #

  @methods [:get, :put, :post, :delete, :options, :head, :patch, :trace]

  @spec collect_operations_and_schemas(State.t()) :: State.t()
  defp collect_operations_and_schemas(state) do
    %State{implementation: implementation, spec: %Spec{paths: paths}} = state

    for {_path, item} <- paths,
        method <- @methods,
        operation_spec = Map.get(item, method),
        implementation.include_operation?(state, operation_spec),
        reduce: state do
      state ->
        process_operation(state, operation_spec)
        |> IO.inspect(pretty: true, syntax_colors: IO.ANSI.syntax_colors())

        # collect_response_body(operation_spec)

        state
    end
  end

  @spec process_operation(State.t(), OperationSpec.t()) :: Operation.t()
  defp process_operation(state, operation_spec) do
    %State{implementation: implementation} = state

    %OperationSpec{
      "$oag_path": request_path,
      "$oag_path_parameters": params_from_path,
      parameters: params_from_operation
    } = operation_spec

    all_params = Enum.map(params_from_path ++ params_from_operation, &Param.from_spec/1)
    path_params = Enum.filter(all_params, &(&1.location == :path))
    query_params = Enum.filter(all_params, &(&1.location == :query))

    # TODO: Process schemas here
    request_body =
      implementation.operation_request_body(operation_spec)
      |> Enum.sort_by(fn {content_type, _schema} -> content_type end)
      |> Enum.map(fn {content_type, schema} -> {content_type, schema} end)

    %Operation{
      docstring: implementation.operation_docstring(operation_spec, query_params),
      function_name: implementation.operation_function_name(operation_spec),
      module_name: ToDo,
      request_body: request_body,
      request_method: implementation.operation_request_method(operation_spec),
      request_path: request_path,
      request_path_parameters: path_params,
      request_query_parameters: query_params,
      responses: []
    }
  end

  @spec collect_response_body(OperationSpec.t()) :: [OpenAPI.Spec.Schema.t()]
  defp collect_response_body(%OperationSpec{responses: responses}) when is_map(responses) do
    Enum.map(responses, fn {_status_or_default, %ResponseSpec{content: content}} ->
      Enum.map(content, fn {_content_type, %MediaSpec{schema: schema}} ->
        schema
      end)
    end)
  end
end
