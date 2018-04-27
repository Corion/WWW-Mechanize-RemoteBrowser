package RemoteBrowser;
use strict;
use Moo 2;
no warnings 'experimental::signatures';
use feature 'signatures';
use IO::Async;
use Future;
use Carp 'croak';
Net::Async::WebSocket::Server->VERSION(0.12); # fixes some errors with masked frames

use JSON 'encode_json', 'decode_json';

use Scalar::Util 'weaken';

# This should go into ::Transport so we can support AnyEvent directly as well
# later
use IO::Async::Loop;
use Net::Async::WebSocket::Server;

use Data::Dumper;

has 'loop' => is => 'lazy', default => sub { IO::Async::Loop->new() };
has 'port' => is => 'ro', default => 3000;
has 'connection' => is => 'rw';

has 'outstanding' => is => 'ro', default => sub { {} };

#sub connect( $self, $handler, $url, $logger=undef ) {
#    $logger ||= sub{};
#    die "Got an undefined endpoint" unless defined $url;
#    weaken $handler;
#
#    my $client;
#    $client = Net::Async::WebSocket::Client->new(
#        # Kick off the continous polling
#        on_frame => sub {
#            my( $connection, $message )=@_;
#           use Data::Dumper;
#           warn Dumper \@_;
#            #$handler->on_response( $connection, $message )
#        },
#    );
#    $self->loop->add( $client );
#    $self->{connection} ||= $client;
#
#    $logger->('debug',"Connecting to $url");
#    $client->connect( url => $url, on_connected => sub {
#        $logger->('info',"Connected to $url");
#    })->catch(sub{
#        #require Data::Dumper;
#        #warn "caught";
#        #warn Data::Dumper::Dumper( \@_ );
#        Future->fail( @_ );
#    });
#}

my $messageIndex = 0;

my $k;
sub listen( $self, $port=$self->port ) {
    my $client_connected = $self->future;
    my $server; $server = Net::Async::WebSocket::Server->new(
        on_client => sub {
            my ( undef, $client ) = @_;
            $self->connection( $client );

            $client->configure(
               on_text_frame => sub {
                 my ( $s, $frame ) = @_;
                 if( length( $frame ) == 4 and $frame eq 'ping' ) { # yeah, hand-rolled pings
                     $self->connection->send_text_frame( 'pong' );
                     return
                  };
                 my $p = decode_json( $frame );
                 if( $p->{clientType}) {
                     $self->connection->send_text_frame( encode_json {"success" => JSON::true(), reply => JSON::true } );

                 } elsif( $p->{channel} eq 'initialConnection') {
                     # initial client connected
                     $messageIndex = $p->{messageIndex};

                     #$self->reply( $p, {"success" => JSON::true(), reply => JSON::true } );
                     #$k = $self->setup_connection( $client );
                     print "Connected\n";
                     $client_connected->done($self, $client, $p );
                  } elsif( $p->{response} ) {
                      $self->handle_response( $p );

                 } else {
                     print "Unknown, ignored\n";
                     warn Dumper $frame;
                     # Try to send a command
                     #$self->send( {"success" => JSON::true() } ); # await browser.tabs.update({ "url": "about:blank" })' );
                      # browser.tabs.update({ url: 'https://intoli.com/blog' })
                     #$self->send( {"channel" => "evaluateInBackground", data => {'asyncFunction' => 'async (args) => (browser.tabs.create(args))', args =>[{ "url" => "https://datenzoo.de" }]}, messageIndex => $i++, response => JSON::false() } );
                      # get tab id
                     #$self->send( {"channel" => "evaluateInContent", data => {'asyncFunction' => 'async (args) => (window.alert(args))', args =>["Hello"]}, response => JSON::false(), id => 1 } );
                 };
               },
            );

        }
    );

    $self->loop->add( $server );

    $server->listen(
        service => $port,
    )->then( sub {
        $client_connected
    })
};

sub addTab_future( $self, $url='about:blank' ) {
    $self->evaluateInBackground( 'async (args) => (browser.tabs.create(args))', { "url" => "$url" } )
    ->then(sub($tab) {
        #warn Dumper $p->{result};
        $self->{tab} = $tab;
        $self->future->done( $tab )
    })
}

sub setup_connection( $self, $connection, %options ) {
    $self->addTab_future($options{ url })
    ->then( sub {
        my( $tab ) = @_;
        #warn "Running in page";
        #$self->send( {"channel" => "evaluateInContent", data => {tabId => $tab->{id}, 'asyncFunction' => 'async (args) => (window.alert(args))', args =>["Hello"]}, response => JSON::false() } );
        Future->done( $tab )
    })->catch( sub {
         warn "*** Error:";
         warn Dumper \@_;
    });
}

sub handle_response( $self, $response ) {
    print Dumper $response;
    my $id = $response->{messageIndex};

    my $inReplyTo = delete $self->outstanding->{ $id };
    if( $inReplyTo ) {
        print sprintf "[ %03d - %s ] <= %s\n", $id, $inReplyTo, Dumper $response->{data};
        eval { $inReplyTo->done( $response->{data} ); };
        warn $@ if $@;
    } else {
        print "Don't know recipient for [$id]\n";
    };
}

sub send( $self, $message ) {
    my $idx = $messageIndex++;
    $message->{messageIndex} = $idx;
    my $res = $self->outstanding->{$idx} = $self->future;
    my $payload = encode_json( $message );
    print sprintf "[ %03d - %s ] => %s\n", $idx, $res, $payload;
    $self->send_text( $payload );
    $res
}

sub send_text( $self, $message ) {
    $self->connection->send_text_frame( $message )
}

sub reply( $self, $message, $reply ) {
    my $idx = $message->{messageIndex}
        or croak "Can't reply without a messageIndex token";
    my $r = {
        channel => $message->{channel},
        data => $reply,
        reply => JSON::true(),
    };
    my $payload = encode_json( $r );
    print sprintf "[ %03d - ] => %s\n", $idx, $payload;
    $self->send_text( $payload );
}

sub close( $self ) {
    my $c = delete $self->{connection};
    $c->finish
        if $c;
    delete $self->{ua};
}

sub future( $self ) {
    $self->loop->new_future;
}

sub connectionUrl( $self ) {
    sprintf 'ws://localhost:%d', $self->port;
};

sub evaluateInBackground( $self, $js, @args ) {
    $self->send( { "channel" => "evaluateInBackground", data => {'asyncFunction' => $js, args => \@args, response => JSON::false() }} )
    ->then(sub( $p ) {
        if( $p->{result}) {
            return Future->done( $p->{result})
        } elsif( $p->{error} ) {
            return Future->fail( remoteError => %{ $p->{error} });
        } else {
            return Future->fail( remoteError => $p );
        }
    });
}

sub evaluateInContent( $self, $tab, $js, @args ) {
    $self->send( { "channel" => "evaluateInContent", data => {'asyncFunction' => $js, args => \@args, tabId => $tab->{id} } })
    ->then(sub( $p ) {
        if( $p->{result}) {
            return Future->done( $p->{result})
        } elsif( $p->{error} ) {
            return Future->fail( remoteError => %{ $p->{error} });
        } else {
            return Future->fail( remoteWeirdError => $p );
        }
    })
}

package main;
use strict;
no warnings 'experimental::signatures';
use feature 'signatures';
use Data::Dumper;

use Path::Class 'dir';
use Test::HTTP::LocalServer;

my $server = Test::HTTP::LocalServer->spawn();

my $b = RemoteBrowser->new();
my $url = $b->connectionUrl;
my $client = $b->listen();

my $sessionId = time();
#$url =~ s!([:/])!sprintf '%%%02x', ord $1!ge;
my $browserUrl = "https://example.com?remoteBrowserUrl=${url}&remoteBrowserSessionId=${sessionId}";
#my $browserUrl = "https://datenzoo.de?remoteBrowserUrl=${url}&remoteBrowserSessionId=${sessionId}";

print "$browserUrl\n";

my $chrome_exe = 'C:/Users/Corion/Projekte/WWW-Mechanize-Chrome/chrome-versions/chrome-win32-67.0.3394.0/chrome.exe';
my $extension_path = dir('dist/extension')->absolute();
my @cmd = ($chrome_exe, "--profile=.\\profile", "--load-extension=$extension_path", qq{"$browserUrl"});
my $cmd = join " ", @cmd;
warn "[[$cmd]]";
system 1, $cmd;

sub eval_in_page( $self, $js, @args ) {
    my $inject = qq((function(args) {\n$js\n})());
    $inject =~ s!\n!\\n!g;
    $inject =~ s!"!\\"!g;
    my $code = <<JS;
var script = document.createElement('script');
script.textContent = "$inject";
(document.head||document.documentElement).appendChild(script);
script.remove();
JS
    $self->evaluateInContent($inject);
    # https://stackoverflow.com/questions/9515704/insert-code-into-the-page-context-using-a-content-script
}

sub content_future( $self, $tab ) {
    $self->evaluateInContent($tab, 'async () => (document.documentElement.outerHTML)');
}

sub content( $self, $tab=$self->{tab} ) {
    content_future($self, $tab)->get
}

# load URL and wait for the tab to finish loading
# also, Window.onready
# also webRequest API
#function createTab (url) {
#    return new Promise(resolve => {
#        chrome.tabs.create({url}, async tab => {
#            chrome.tabs.onUpdated.addListener(function listener (tabId, info) {
#                if (info.status === 'complete' && tabId === tab.id) {
#                    chrome.tabs.onUpdated.removeListener(listener);
#                    resolve(tab);
#                }
#            });
#        });
#    });
#}

#$b->connect(undef, 'ws://localhost:8000')->get;

my $printed = $client->then(sub( $self, $conn, $p ) {
    #print "Setting up\n";
    $self->setup_connection( $conn, url => $server->url )
})->then(sub {
    print "Connected and set up\n";

    #print Dumper content($b);

    #is_deeply $b->evaluateInContent( $b->{tab}, 'async () => ( {"foo":"bar"} )' )->get, {foo=>'bar'};
    #is $b->evaluateInContent( $b->{tab}, 'async () => ( 1+1 )' )->get, 2;
    #is_deeply $b->evaluateInContent( $b->{tab}, 'async (args) => ( args )', {foo => { bar => "baz" }} ), {foo => { bar => "baz" }};
    #fails_ok $b->evaluateInContent( $b->{tab}, '(args) => ( referenceError )' ), {remoteError, name => 'RemoteError', { name => 'ReferenceError' }};
    #$b->evaluateInContent( $b->{tab}, 'async () => ( window )' );
    #$b->evaluateInContent( $b->{tab}, 'async () => ( document.body.style["background-color"] = "blue" )' );
    $b->evaluateInContent( $b->{tab}, 'async () => ( document.querySelector("a").click() )' );


    #content_future( $b, $b->{tab} );

    #$b->evaluateInBackground( <<'JS', $b->{tab}->{id} );
    #    async function (tabId) {
    #        return new Promise(function( resolve, reject ) {
    #            browser.tabs.get(tabId, resolve)
    #        });
    #    };
#JS

})->then( sub( $res ) {
    sleep 10;
    $b->connection->send_close_frame;
})->then(sub {
    warn "Stopping loop";
    $b->loop->stop;
    Future->done;
})->catch(sub {
    warn "*** Error";
    warn Dumper \@_;
});

$b->loop->run;

$server->kill;
wait;

# (and other window properties)