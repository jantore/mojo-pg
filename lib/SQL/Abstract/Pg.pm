package SQL::Abstract::Pg;
use Mojo::Base 'SQL::Abstract';

BEGIN { *puke = \&SQL::Abstract::puke }

sub insert {
  my ($self, $table, $data, $options) = @_;
  local @{$options}{qw(returning _pg_returning)} = (1, 1)
    if exists $options->{on_conflict} && !$options->{returning};
  return $self->SUPER::insert($table, $data, $options);
}

sub new {
  my $self = shift->SUPER::new(@_);

  # -json op
  push @{$self->{unary_ops}}, {
    regex   => qr/^json$/,
    handler => sub { '?', {json => $_[2]} }
  };

  return $self;
}

sub select {
  my ($self, $table, $fields, @args) = @_;

  if (ref $fields eq 'ARRAY') {
    my @fields;
    for my $field (@$fields) {
      if (ref $field eq 'ARRAY') {
        puke 'field alias must be in the form [$name => $alias]' if @$field < 2;
        push @fields,
            $self->_quote($field->[0])
          . $self->_sqlcase(' as ')
          . $self->_quote($field->[1]);
      }
      elsif (ref $field eq 'SCALAR') { push @fields, $$field }
      else                           { push @fields, $self->_quote($field) }
    }
    $fields = join ', ', @fields;
  }

  return $self->SUPER::select($table, $fields, @args);
}

sub _insert_returning {
  my ($self, $options) = @_;

  delete $options->{returning} if $options->{_pg_returning};

  # ON CONFLICT
  my $sql = '';
  my @bind;
  if (exists $options->{on_conflict}) {
    my $conflict = $options->{on_conflict};
    my ($conflict_sql, @conflict_bind);
    $self->_SWITCH_refkind(
      $conflict => {
        ARRAYREF => sub {
          my ($target, $set) = @$conflict;
          puke 'on_conflict value must be in the form [$target, \%set]'
            unless ref $set eq 'HASH';
          $target = [$target] unless ref $target eq 'ARRAY';

          $conflict_sql
            = '(' . join(', ', map { $self->_quote($_) } @$target) . ')';
          $conflict_sql .= $self->_sqlcase(' do update set ');
          my ($set_sql, @set_bind) = $self->_update_set_values($set);
          $conflict_sql .= $set_sql;
          push @conflict_bind, @set_bind;
        },
        ARRAYREFREF => sub { ($conflict_sql, @conflict_bind) = @$$conflict },
        SCALARREF => sub { $conflict_sql = $$conflict },
        UNDEF => sub { $conflict_sql = $self->_sqlcase('do nothing') }
      }
    );
    $sql .= $self->_sqlcase(' on conflict ') . $conflict_sql;
    push @bind, @conflict_bind;
  }

  $sql .= $self->SUPER::_insert_returning($options) if $options->{returning};

  return $sql, @bind;
}

sub _order_by {
  my ($self, $options) = @_;

  # Legacy
  return $self->SUPER::_order_by($options)
    if ref $options ne 'HASH'
    or grep {/^-(?:desc|asc)/i} keys %$options;

  # GROUP BY
  my $sql = '';
  my @bind;
  if (defined(my $group = $options->{group_by})) {
    my $group_sql;
    $self->_SWITCH_refkind(
      $group => {
        ARRAYREF => sub {
          $group_sql = join ', ', map { $self->_quote($_) } @$group;
        },
        SCALARREF => sub { $group_sql = $$group }
      }
    );
    $sql .= $self->_sqlcase(' group by ') . $group_sql;
  }

  # HAVING
  if (defined(my $having = $options->{having})) {
    my ($having_sql, @having_bind) = $self->_recurse_where($having);
    $sql .= $self->_sqlcase(' having ') . $having_sql;
    push @bind, @having_bind;
  }

  # ORDER BY
  $sql .= $self->_order_by($options->{order_by})
    if defined $options->{order_by};

  # LIMIT
  if (defined $options->{limit}) {
    $sql .= $self->_sqlcase(' limit ') . '?';
    push @bind, $options->{limit};
  }

  # OFFSET
  if (defined $options->{offset}) {
    $sql .= $self->_sqlcase(' offset ') . '?';
    push @bind, $options->{offset};
  }

  # FOR
  if (defined(my $for = $options->{for})) {
    my $for_sql;
    $self->_SWITCH_refkind(
      $for => {
        SCALAR => sub {
          puke qq{for value "$for" is not allowed} unless $for eq 'update';
          $for_sql = $self->_sqlcase('UPDATE');
        },
        SCALARREF => sub { $for_sql .= $$for }
      }
    );
    $sql .= $self->_sqlcase(' for ') . $for_sql;
  }

  return $sql, @bind;
}

sub _table {
  my ($self, $table) = @_;

  return $self->SUPER::_table($table) unless ref $table eq 'ARRAY';

  my (@table, @join);
  for my $t (@$table) {
    if   (ref $t eq 'ARRAY') { push @join,  $t }
    else                     { push @table, $t }
  }

  $table = $self->SUPER::_table(\@table);
  my $sep = $self->{name_sep} // '';
  for my $join (@join) {
    puke 'join must be in the form [$table, $fk => $pk]' if @$join < 3;
    my $type = @$join > 3 ? shift @$join : '';
    my ($name, $fk, $pk) = @$join;
    my $op;
    ($op, $pk) = ref $pk eq 'HASH' ? %$pk : ('=', $pk);
    $table
      .= $self->_sqlcase($type =~ /^-(.+)$/ ? " $1 join " : ' join ')
      . $self->_quote($name)
      . $self->_sqlcase(' on ') . '('
      . $self->_quote(index($fk, $sep) > 0 ? $fk : "$name.$fk") . " $op "
      . $self->_quote(index($pk, $sep) > 0 ? $pk : "$table[0].$pk") . ')';
  }

  return $table;
}

1;

=encoding utf8

=head1 NAME

SQL::Abstract::Pg - PostgreSQL

=head1 SYNOPSIS

  use SQL::Abstract::Pg;

  my $abstract = SQL::Abstract::Pg->new;
  say $abstract->select('some_table');

=head1 DESCRIPTION

L<SQL::Abstract::Pg> extends L<SQL::Abstract> with a few PostgreSQL features
used by L<Mojo::Pg>.

=head2 JSON

In many places (as supported by L<SQL::Abstract>) you can use the C<-json> unary
op to encode JSON from Perl data structures.

  # "update some_table set foo = '[1,2,3]' where bar = 23"
  $abstract->update('some_table', {foo => {-json => [1, 2, 3]}}, {bar => 23});

  # "select * from some_table where foo = '[1,2,3]'"
  $abstract->select('some_table', '*', {foo => {'=' => {-json => [1, 2, 3]}}});

=head1 INSERT

  $abstract->insert($table, \@values || \%fieldvals, \%options);

=head2 ON CONFLICT

The C<on_conflict> option can be used to generate C<INSERT> queries with
C<ON CONFLICT> clauses. So far C<undef> to pass C<DO NOTHING>, array references
to pass C<DO UPDATE> with conflict targets and a C<SET> expression, scalar
references to pass literal SQL and array reference references to pass literal
SQL with bind values are supported.

  # "insert into t (a) values ('b') on conflict do nothing"
  $abstract->insert('t', {a => 'b'}, {on_conflict => undef});

  # "insert into t (a) values ('b') on conflict do nothing"
  $abstract->insert('t', {a => 'b'}, {on_conflict => \'do nothing'});

This includes operations commonly referred to as C<upsert>.

  # "insert into t (a) values ('b') on conflict (a) do update set a = 'c'"
  $abstract->insert('t', {a => 'b'}, {on_conflict => [a => {a => 'c'}]});

  # "insert into t (a, b) values ('c', 'd')
  #  on conflict (a, b) do update set a = 'e'"
  $abstract->insert(
    't', {a => 'c', b => 'd'}, {on_conflict => [['a', 'b'] => {a => 'e'}]});

  # "insert into t (a) values ('b') on conflict (a) do update set a = 'c'"
  $abstract->insert(
    't', {a => 'b'}, {on_conflict => \['(a) do update set a = ?', 'c']});

=head1 SELECT

  $abstract->select($source, $fields, $where, $order);
  $abstract->select($source, $fields, $where, \%options);

=head2 AS

The C<$fields> argument now also accepts array references containing array
references with field names and aliases, as well as array references containing
scalar references to pass literal SQL.

  # "select foo as bar from some_table"
  $abstract->select('some_table', [[foo => 'bar']]);

  # "select foo, bar as baz, yada from some_table"
  $abstract->select('some_table', ['foo', [bar => 'baz'], 'yada']);

  # "select extract(epoch from foo) as foo, bar from some_table"
  $abstract->select('some_table', [\'extract(epoch from foo) as foo', 'bar']);

=head2 JOIN

The C<$source> argument now also accepts array references containing not only
table names, but also array references with tables to generate C<JOIN> clauses
for.

  # "select * from foo join bar on (bar.foo_id = foo.id)"
  $abstract->select(['foo', ['bar', foo_id => 'id']]);

  # "select * from foo join bar on (foo.id = bar.foo_id)"
  $abstract->select(['foo', ['bar', 'foo.id' => 'bar.foo_id']]);

  # "select * from a join b on (b.a_id = a.id) join c on (c.a_id = a.id)"
  $abstract->select(['a', ['b', a_id => 'id'], ['c', a_id => 'id']]);

  # "select * from foo left join bar on (bar.foo_id = foo.id)"
  $abstract->select(['foo', [-left => 'bar', foo_id => 'id']]);

=head2 ORDER BY

Alternatively to the C<$order> argument accepted by L<SQL::Abstract> you can now
also pass a hash reference with various options. This includes C<order_by>,
which takes the same values as the C<$order> argument.

  # "select * from some_table order by foo desc"
  $abstract->select('some_table', '*', undef, {order_by => {-desc => 'foo'}});

=head2 LIMIT/OFFSET

The C<limit> and C<offset> options can be used to generate C<SELECT> queries
with C<LIMIT> and C<OFFSET> clauses.

  # "select * from some_table limit 10"
  $abstract->select('some_table', '*', undef, {limit => 10});

  # "select * from some_table offset 5"
  $abstract->select('some_table', '*', undef, {offset => 5});

  # "select * from some_table limit 10 offset 5"
  $abstract->select('some_table', '*', undef, {limit => 10, offset => 5});

=head2 GROUP BY

The C<group_by> option can be used to generate C<SELECT> queries with
C<GROUP BY> clauses. So far array references to pass a list of fields and scalar
references to pass literal SQL are supported.

  # "select * from some_table group by foo, bar"
  $abstract->select('some_table', '*', undef, {group_by => ['foo', 'bar']});

  # "select * from some_table group by foo, bar"
  $abstract->select('some_table', '*', undef, {group_by => \'foo, bar'});

=head2 HAVING

The C<having> option can be used to generate C<SELECT> queries with C<HAVING>
clauses, which takes the same values as the C<$where> argument.

  # "select * from t group by a having b = 'c'"
  $abstract->select('t', '*', undef, {group_by => ['a'], having => {b => 'c'}});

=head2 FOR

The C<for> option can be used to generate C<SELECT> queries with C<FOR> clauses.
So far the scalar value C<update> to pass C<UPDATE> and scalar references to
pass literal SQL are supported.

  # "select * from some_table for update"
  $abstract->select('some_table', '*', undef, {for => 'update'});

  # "select * from some_table for update skip locked"
  $abstract->select('some_table', '*', undef, {for => \'update skip locked'});

=head1 METHODS

L<SQL::Abstract::Pg> inherits all methods from L<SQL::Abstract>.

=head1 SEE ALSO

L<Mojo::Pg>, L<Mojolicious::Guides>, L<http://mojolicious.org>.

=cut
