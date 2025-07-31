# ruby-template 🧰

[![test](https://github.com/GrantBirki/ruby-template/actions/workflows/test.yml/badge.svg)](https://github.com/GrantBirki/ruby-template/actions/workflows/test.yml)
[![lint](https://github.com/GrantBirki/ruby-template/actions/workflows/lint.yml/badge.svg)](https://github.com/GrantBirki/ruby-template/actions/workflows/lint.yml)
[![build](https://github.com/GrantBirki/ruby-template/actions/workflows/build.yml/badge.svg)](https://github.com/GrantBirki/ruby-template/actions/workflows/build.yml)
[![tarball](https://github.com/GrantBirki/ruby-template/actions/workflows/tarball.yml/badge.svg)](https://github.com/GrantBirki/ruby-template/actions/workflows/tarball.yml)

## About ⭐

A template repository for building Ruby applications, services, and libraries.

This project heavily leverages GitHub's architecture patterns such as:

- [Scripts to Rule them All](https://github.blog/engineering/scripts-to-rule-them-all/)
- Dependency Vendoring ([`vendor/cache/`](vendor/cache/))
- Usage of [rbenv](https://github.com/rbenv/rbenv)

## Usage 💻

All of the scripts defined below follow GitHub's [Scripts to Rule them All](https://github.blog/engineering/scripts-to-rule-them-all/) pattern. This pattern is a set of well-defined scripts that are used to perform common tasks such as bootstrapping, testing, linting, and more. These scripts are defined in the [`script/`](script/) directory.

### Bootstrapping

> First, ensure you have [rbenv](https://github.com/rbenv/rbenv) installed

To bootstrap the project and install all dependencies (RubyGems), run the following command:

```bash
script/bootstrap
```

You can also alter this command to only install gems for production builds/environments:

```bash
script/bootstrap --production
```

Gems will be installed locally into the `vendor/gems/` directory at the root of this repository.

### Testing

After bootstrapping the project, you can run the test suite:

```bash
script/test
```

By default, this project enforces 100% code coverage. After running `script/test`, you can view the code coverage report in the `coverage/` directory at the root of the repository.

### Linting

To lint the project, run the following command:

```bash
script/lint
```

The linter that this project uses is [rubocop](https://github.com/rubocop/rubocop) and its configuration is defined in the [`.rubocop.yml`](.rubocop.yml) file.

### Docker Builds

Build a Docker image:

```bash
script/docker-build
```

The result of this command will be a Docker image built with the name `ruby-template:latest`.

This script:

1. Builds a Docker image using the `Dockerfile` in the root of the repository.
2. Tags the image with the `latest` tag.

### Building Tarballs

To build a tarball of the application for deployment, run the following command:

```bash
script/tarball
```

This will build a docker container and run the `script/build-deploy-tarball` script inside the container. The result will be a tarball in the `tarballs/` directory at the root of the repository.

Tarballs are popular for atomic deployments where the deployment is a simple matter of extracting the tarball to the correct location on the target machine and running the new version of the application. Tarball deploys help to shift the complexity of the deployment process from the target machine to the build server (in this case, the CI server - Actions).

This script:

1. Builds a Docker image using the `Dockerfile` in the root of the repository.
2. Inside of the Docker container it:
    1. Install all dependencies
    2. Creates a compressed tarball with all the source code and dependencies. The dependenices are even pre-installed to save time when deploying the application. This means that the `vendor/cache/*.gem` files have been installed via bundler into the `vendor/gems/` directory.
    3. Adds commit metadata to the tarball by dropping `BUILD_SHA` and `BUILD_BRANCH` files in the root of the tarball
3. Drops the tarball in the `tarballs/` directory at the root of the repository.

From this point, you would have a file named `tarballs/linux-aarch64-bookworm-sha123abc.tar.gz` (just an example) that would exist either on your local machine (or in a CI system) that you could use to deploy the application to a server.

See the [Dockerfile.tarball](spec/acceptance/Dockerfile.tarball) file for an example of how to unpack this pre-built tarball and run the application. It doesn't even require `script/bootstrap` to be called or `apt-get` packages to be installed (in most cases) - neat!

### Running the Application/Server

Remember, this is just a template repository so this command won't really do anything. This template is a simple app that adds the numbers `1` and `2` together. Run it with the following command:

```bash
script/server # result: 3
```

If you bootstrapped the project for a production environment, you need to run the server in production mode:

> Example shows bootstrapping the project for production and then running the server in production mode.

```bash
# if you want to run the server in production mode, you must first bootstrap the project for production
# this will install only the production dependencies and skip development dependencies
script/bootstrap --production

# then you must also run the server in production mode
script/server --production
```

### Build

Define the specific build steps in the `script/build` script.

A build script for Ruby might look something [like this](https://github.com/runwaylab/issue-db/blob/a6f8889e661bf4d2afc46366b8b4095fd9941ecf/.github/workflows/build.yml#L32-L45).

### Releasing

The `script/release` script is a starting point for pushing and tagging new releases on GitHub.

## Vendoring

This project adopts a "vendor everything" approach to dependencies. This means that all dependencies are vendored into the repository. This is done to ensure that the build is reproducible and that the build is not dependent on the availability of external dependencies (e.g. RubyGems.org).

All Ruby Gems are committed to version control and stored in the [`vendor/cache/`](vendor/cache/) directory.

This behavior is further controlled by the [`.bundle/config`](./.bundle/config) file.
