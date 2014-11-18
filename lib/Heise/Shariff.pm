package Heise::Shariff;
use Mojo::Base 'Mojolicious';

use Heise::Shariff::Cache;
use Mojo::Date;
use Mojo::Loader;

our $VERSION  = '1.05';

has service_namespaces => sub {['Heise::Shariff::Service']};

sub startup {
    my $self = shift;

    $self->plugin('Config');

    $self->helper(cache => sub {
        state $cache = Heise::Shariff::Cache->new(
            expires => shift->config->{cache}->{expires}
        );
    });

    $self->helper(services => sub {
        my @services;
        my $loader = Mojo::Loader->new;
        for my $ns (@{$self->service_namespaces}) {
            for my $module (@{$loader->search($ns)}) {
                my $e = $loader->load($module);
                warn qq{Loading "$module" failed: $e} and next if ref $e;
                push @services, $module->new;
            }
        }
        return \@services;
    });

    $self->helper(render_json => sub {
        my ($c, $counts, $last_modified) = @_;
        my $headers = $c->res->headers;
        $headers->cache_control('public, max-age=60');
        $headers->last_modified($last_modified);
        $c->render(json => $counts);
    });

    $self->helper(get_counts => sub {
        my ($c, $url) = @_;

        if (my $data = $c->cache->get($url)) {
            return $c->render_json($data->{counts}, $data->{requested});
        }

        my @services = @{$c->services};

        $c->app->log->debug('sending concurrent requests ...');

        $c->delay(
            sub {
                my $delay = shift;
                for my $service (@services) {
                    my $request = $service->request($url);
                    $c->ua->start(
                        $c->ua->build_tx(@{$service->request($url)}),
                        $delay->begin
                    );
                }
            },
            sub {
                my ($delay, @transactions) = @_;

                my %counts;

                for (my $i = 0; $i < @transactions; $i++) {
                    # warn dumper $transactions[$i]->res;
                    my $service = $services[$i];
                    $counts{ $service->get_name } =
                      $service->extract_count($transactions[$i]->res)
                }

                my %data = (
                    counts    => \%counts,
                    requested => Mojo::Date->new,
                );

                $c->cache->set($url => \%data);
                $c->render_json($data{counts}, $data{requested});
            }
        );
    });

    $self->validation->validator->add_check(matches_domain => sub {
        my ( $validation, $name, $value, $domain ) = @_;
        return Mojo::URL->new($value)->host !~ $domain;
    });

    my $r = $self->routes;

    $r->get('/' => sub {
        my $c = shift;
        my $validation = $c->validation;

        $validation->required("url")->matches_domain($c->config->{domain});

        return $c->render(json => {error => "invalid url"}, status => 400)
          if $validation->has_error;

        $c->get_counts($validation->param('url'));
    });
}

1;
