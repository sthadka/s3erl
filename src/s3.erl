%%%-------------------------------------------------------------------
%%% File    : s3.erl
%%% Author  : Andrew Birkett <andy@nobugs.org>
%%% Description : 
%%%
%%% Created : 14 Nov 2007 by Andrew Birkett <andy@nobugs.org>
%%%-------------------------------------------------------------------
-module(s3).

-behaviour(gen_server).

%% API
-export([ start/1,
	  list_buckets/1, create_bucket/2, delete_bucket/2,
	  list_objects/3, list_objects/2, write_object/5, read_object/3, delete_object/3 ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, 
	 terminate/2, code_change/3]).

-include_lib("xmerl/include/xmerl.hrl").
-include("../include/s3.hrl").

-define(TIMEOUT, infinity).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start(AwsCredentials) ->
    gen_server:start_link(?MODULE, AwsCredentials, []).

create_bucket(Pid, Name) -> gen_server:call(Pid, {put, Name} ).
delete_bucket(Pid, Name) -> gen_server:call(Pid, {delete, Name} ).
list_buckets(Pid)      -> gen_server:call(Pid, {listbuckets}).

write_object (Pid, Bucket, Key, Data, ContentType) -> 
    gen_server:call(Pid, {put, Bucket, Key, Data, ContentType}, ?TIMEOUT).
read_object (Pid, Bucket, Key) -> 
    gen_server:call(Pid, {get, Bucket, Key}, ?TIMEOUT).
delete_object (Pid, Bucket, Key) -> 
    gen_server:call(Pid, {delete, Bucket, Key}, ?TIMEOUT).

%% option example: [{delimiter, "/"},{maxresults,10},{prefix,"/foo"}]
list_objects (Pid, Bucket, Options ) -> gen_server:call(Pid, {list, Bucket, Options }).
list_objects (Pid, Bucket) -> list_objects( Pid, Bucket, [] ).


%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init(AwsCredentials) ->
    crypto:start(),
    inets:start(),
    {ok, AwsCredentials}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------

% Bucket operations
handle_call({listbuckets}, _From, AwsCredentials) ->
    { reply, xmlToBuckets(getRequest( AwsCredentials, "", "", [] )), AwsCredentials };

handle_call({ put, Bucket }, _From, AwsCredentials) ->
    {_Headers,_Body} = putRequest( AwsCredentials,Bucket, "", <<>>, ""),
    { reply, {ok}, AwsCredentials };

handle_call({delete, Bucket }, _From, AwsCredentials) ->
    try 
	{_Headers,_Body} = deleteRequest( AwsCredentials, Bucket, ""),
	{ reply, {ok}, AwsCredentials }
    catch
	throw:X -> { reply, X, AwsCredentials }
    end;

% Object operations
handle_call({put, Bucket, Key, Content, ContentType }, _From, AwsCredentials) ->
	try
    {Headers,_Body} = putRequest( AwsCredentials,Bucket, Key, Content, ContentType),
    {value,{"ETag",ETag}} = lists:keysearch( "ETag", 1, Headers ),
    {reply, {ok, ETag}, AwsCredentials}
	catch
	throw:X -> { reply, X, AwsCredentials }
	end;

handle_call({ list, Bucket, Options }, _From, AwsCredentials) ->
    Headers = lists:map( fun option_to_param/1, Options ),
    {_, Body} = getRequest( AwsCredentials, Bucket, "", Headers ),
    {reply, parseBucketListXml(Body), AwsCredentials};

handle_call({ get, Bucket, Key }, _From, AwsCredentials) ->
    try
	{reply, getRequest( AwsCredentials, Bucket, Key, [] ), AwsCredentials}
    catch
	throw:X -> { reply, X, AwsCredentials }
    end;

handle_call({delete, Bucket, Key }, _From, AwsCredentials) ->
    try 
	{_Headers,_Body} = deleteRequest( AwsCredentials, Bucket, Key),
	{reply, {ok}, AwsCredentials}
    catch
	throw:X -> { reply, X, AwsCredentials }
    end.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

s3Host () ->
    "s3.amazonaws.com".

option_to_param( { prefix, X } ) -> 
    { "prefix", X };
option_to_param( { maxkeys, X } ) -> 
    { "max-keys", integer_to_list(X) };
option_to_param( { delimiter, X } ) -> 
    { "delimiter", X }.

getRequest( AwsCredentials, Bucket, Key, Headers ) ->
    genericRequest( AwsCredentials, get, Bucket, Key, Headers, <<>>, "" ).
putRequest( AwsCredentials, Bucket, Key, Content, ContentType ) ->
    genericRequest( AwsCredentials, put, Bucket, Key, [], Content, ContentType ).
deleteRequest( AwsCredentials, Bucket, Key ) ->
    genericRequest( AwsCredentials, delete, Bucket, Key, [], <<>>, "" ).


isAmzHeader( Header ) -> lists:prefix("x-amz-", Header).

canonicalizedAmzHeaders( AllHeaders ) ->
    AmzHeaders = [ {string:to_lower(K),V} || {K,V} <- AllHeaders, isAmzHeader(K) ],
    Strings = lists:map( 
		fun s3util:join/1, 
		s3util:collapse( 
		  lists:keysort(1, AmzHeaders) ) ),
    s3util:string_join( lists:map( fun (S) -> S ++ "\n" end, Strings), "").
    
canonicalizedResource ( "", "" ) -> "/";
canonicalizedResource ( Bucket, "" ) -> "/" ++ Bucket ++ "/";
canonicalizedResource ( Bucket, Path ) -> "/" ++ Bucket ++ "/" ++ Path.

stringToSign ( Verb, ContentMD5, ContentType, Date, Bucket, Path, OriginalHeaders ) ->
    Parts = [ Verb, ContentMD5, ContentType, Date, canonicalizedAmzHeaders(OriginalHeaders)],
    s3util:string_join( Parts, "\n") ++ canonicalizedResource(Bucket, Path).
    
sign (Key,Data) ->
%    io:format("Data being signed is ~p~n", [Data]),
    binary_to_list( base64:encode( crypto:sha_mac(Key,Data) ) ).

queryParams( [] ) -> "";
queryParams( L ) -> 
    Stringify = fun ({K,V}) -> K ++ "=" ++ V end,
    "?" ++ s3util:string_join( lists:map( Stringify, L ), "&" ).

buildHost("") -> s3Host();
buildHost(Bucket) -> Bucket ++ "." ++ s3Host().
    
buildUrl(Bucket,Path,QueryParams) -> 
    "http://" ++ buildHost(Bucket) ++ "/" ++ Path ++ queryParams(QueryParams).

buildContentHeaders( <<>>, _ ) -> [];
buildContentHeaders( Contents, ContentType ) -> 
    [{"Content-Length", integer_to_list(size(Contents))},
     {"Content-Type", ContentType}].

genericRequest( AwsCredentials, Method, Bucket, Path, QueryParams, Contents, ContentType ) ->
    Date = httpd_util:rfc1123_date(),
    MethodString = string:to_upper( atom_to_list(Method) ),
    Url = buildUrl(Bucket,Path,QueryParams),

    OriginalHeaders = buildContentHeaders( Contents, ContentType ),
    ContentMD5 = "",
    Body = Contents,

    #aws_credentials{ accessKeyId=AKI, secretAccessKey=SAK } = AwsCredentials,

    Signature = sign( SAK,
		      stringToSign( MethodString, ContentMD5, ContentType, 
				    Date, Bucket, Path, OriginalHeaders )),

    Headers = [ {"Authorization","AWS " ++ AKI ++ ":" ++ Signature },
		{"Host", buildHost(Bucket) },
		{"Date", Date } 
	       | OriginalHeaders ],
    
    %Request = case Method of
	%	  get -> { Url, Headers };
	%	  put -> { Url, Headers, ContentType, Body };
	%	  delete -> { Url, Headers }
	%      end,
    %HttpOptions = [],
    %Options = [ {sync,true}, {headers_as_is,true} ],

%    io:format("Sending request ~p~n", [Request]),
    %Reply = http:request( Method, Request, HttpOptions, Options ),
    Reply = case Method of
		get -> ibrowse:send_req(Url, Headers, get);
		put -> ibrowse:send_req(Url, Headers, put, Body, [{content_type, ContentType}]);
		delete -> ibrowse:send_req(Url, Headers, delete)
	end,
    
    case Reply of
	%{ok, {{_HttpVersion, Code, _ReasonPhrase}, ResponseHeaders, ResponseBody }} 
	{ok, Code, ResponseHeaders, ResponseBody}
	 when Code=:="200"; Code=:="204"
	      -> 
	    {ResponseHeaders,ResponseBody};

	%{ok, {{_HttpVersion, _HttpCode, _ReasonPhrase}, _ResponseHeaders, ResponseBody }} -> 
	{ok, _Code, _ResponseHeaders, ResponseBody} ->
	    throw ( parseErrorXml(ResponseBody) );
	{error, Reason} ->
		throw ({error, Reason})
    end.


parseBucketListXml (Xml) ->
    {XmlDoc, _Rest} = xmerl_scan:string( Xml ),
    ContentNodes = xmerl_xpath:string("/ListBucketResult/Contents", XmlDoc),

    GetObjectAttribute = fun (Node,Attribute) -> 
		      [Child] = xmerl_xpath:string( Attribute, Node ),
		      {Attribute, s3util:string_value( Child )}
	      end,

    NodeToRecord = fun (Node) ->
			   #object_info{ 
			 key =          GetObjectAttribute(Node,"Key"),
			 lastmodified = GetObjectAttribute(Node,"LastModified"),
			 etag =         GetObjectAttribute(Node,"ETag"),
			 size =         GetObjectAttribute(Node,"Size")}
		   end,
    { ok, lists:map( NodeToRecord, ContentNodes ) }.

parseErrorXml (Xml) ->
    {XmlDoc, _Rest} = xmerl_scan:string( Xml ),
    [#xmlText{value=ErrorCode}]    = xmerl_xpath:string("/Error/Code/text()", XmlDoc),
    [#xmlText{value=ErrorMessage}] = xmerl_xpath:string("/Error/Message/text()", XmlDoc),
    { s3error, ErrorCode, ErrorMessage }.


xmlToBuckets( {_Headers,Body} ) ->
    {XmlDoc, _Rest} = xmerl_scan:string( Body ),
    TextNodes       = xmerl_xpath:string("//Bucket/Name/text()", XmlDoc),
    lists:map( fun (#xmlText{value=T}) -> T end, TextNodes).

