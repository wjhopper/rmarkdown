
# Create a shiny app object from an Rmd w/ runtime: shiny_prerendered
shiny_prerendered_app <- function(input_rmd, encoding, render_args) {

  # get rendered html and capture dependencies
  html <- shiny_prerendered_html(input_rmd, encoding, render_args)
  deps <- attr(html, "html_dependencies")

  # create the server environment
  server_envir = new.env(parent = globalenv())

  # extract the server-start context
  html_lines <- strsplit(html, "\n", fixed = TRUE)[[1]]
  server_start_context <- shiny_prerendered_extract_context(html_lines,
                                                            "server-start")

  # extract the code used for server startup (this encompasses both the
  # context="server-start" code and the context="data" code). This can be
  # retreived later via the shiny_prerendered_server_start_code function. The
  # purpose of this is for appliations which want to run user in other
  # processes while still duplicating the setup context (e.g. tutorials).
  server_start_code <- paste(c(server_start_context,
                               shiny_prerendered_extract_context(html_lines, "data")),
                             collapse = "\n")

  onStart <- function() {

    # save the server_start_code
    assign(".shiny_prerendered_server_start_code", server_start_code, envir = server_envir)

    # execute the startup code (server_start_context + context="data" loading)
    eval(parse(text = server_start_context), envir = server_envir)
    shiny_prerendered_data_load(input_rmd, server_envir)

    # lock the environment to prevent inadvertant assignments
    lockEnvironment(server_envir)
  }

  # extract the server context
  .server_context <- shiny_prerendered_extract_context(html_lines, "server")
  server_envir$.server_context <- .server_context
  server <- function(input, output, session) {
    eval(parse(text = .server_context))
  }
  environment(server) <- new.env(parent = server_envir)

  # remove server code before serving
  server_contexts <-  c("server-start", "data", "server")
  html_lines <- shiny_prerendered_remove_contexts(html_lines, server_contexts)
  html <- HTML(paste(html_lines, collapse = "\n"))
  html <- htmltools::attachDependencies(html, deps)

  # create shiny app
  shiny::shinyApp(
    ui = function(req) html,
    server = server,
    onStart = onStart,
    uiPattern = "^/$|^(/.*\\.[Rr][Mm][Dd])$"
  )
}


# Generate the html for a runtime: shiny_prerendered Rmd (attempts to use
# an existing rendering of the html if it's still valid)
shiny_prerendered_html <- function(input_rmd, encoding, render_args) {

  # determine the path to the rendered_html
  output_file <- render_args$output_file
  if (is.null(output_file))
    output_file <- file_with_ext(basename(input_rmd), "html")
  output_dir <- render_args$output_dir
  if (is.null(output_dir))
    output_dir <- dirname(input_rmd)
  rendered_html <- file.path(output_dir, output_file)

  # determine whether we need to render the Rmd in advance
  prerender_option <- tolower(Sys.getenv("RMARKDOWN_RUN_PRERENDER", "1"))

  if (file.access(output_dir, 2) != 0) {
    prerender <- FALSE
  }
  else if (identical(prerender_option, "0")) {
    prerender <- FALSE
  }
  else if (identical(prerender_option, "1")) {

    # determine the last modified time of the output file
    if (file.exists(rendered_html))
      output_last_modified <- as.integer(file.info(rendered_html)$mtime)
    else
      output_last_modified <- 0L

    # short circuit for Rmd modified. if it hasn't been modified since the
    # html was generated look at external resources
    input_last_modified <- as.integer(file.info(input_rmd)$mtime)
    if (input_last_modified > output_last_modified) {
      prerender <- TRUE
    }
    else {
      # find external resources referenced by the file
      external_resources <- find_external_resources(input_rmd, encoding)

      # get paths to external resources
      input_files <- c(input_rmd,
                       file.path(output_dir, external_resources$path))

      # what's the maximum last_modified time of an input file
      input_last_modified <- max(as.integer(file.info(input_files)$mtime),
                                 na.rm = TRUE)

      # render if an input file was modified after the output file
      prerender <- input_last_modified > output_last_modified
    }
  }
  else {
    stop("Invalid value '", prerender_option, "' for RMARKDOWN_RUN_PRERENDER")
  }

  # prerender if necessary
  if (prerender) {

    # execute the render
    args <- merge_lists(list(input = input_rmd,
                             encoding = encoding,
                             envir = new.env()),
                        render_args)
    rendered_html <- do.call(render, args)
  }

  # normalize paths
  rendered_html <- normalize_path(rendered_html, winslash = "/")
  output_dir <- dirname(rendered_html)

  # add some resource paths
  add_resource_path <- function(path) {
    if (dir_exists(path))
      shiny::addResourcePath(basename(path), path)
  }
  files_dir <- knitr_files_dir(rendered_html)
  add_resource_path(files_dir)
  add_resource_path(file.path(output_dir,"css"))
  add_resource_path(file.path(output_dir,"js"))
  add_resource_path(file.path(output_dir,"images"))
  add_resource_path(file.path(output_dir,"www"))

  # extract dependencies from html
  html_lines <- readLines(rendered_html, encoding = "UTF-8", warn = FALSE)
  dependencies_json <- shiny_prerendered_extract_context(html_lines, "dependencies")
  dependencies <- jsonlite::unserializeJSON(dependencies_json)

  # resolve package paths (this will happen automatically for the
  # development version of htmltools but this isn't on CRAN yet)
  dependencies <- lapply(dependencies, function(dependency) {
    if (!is.null(dependency$package) && !is.null(dependency$src$file)) {
      dependency$src$file <- system.file(dependency$src$file,
                                         package = dependency$package)
      dependency$package <- NULL
    }
    dependency
  })

  # attach rstudio rsiframe script if we are in rstudio
  if (nzchar(Sys.getenv("RSTUDIO")))
    dependencies <- append(dependencies, list(html_dependency_rsiframe()))

  # return html w/ dependencies
  shinyHTML_with_deps(rendered_html, dependencies)
}


# Write the dependencies for a shiny_prerendered document.
#' @import rprojroot
shiny_prerendered_append_dependencies <- function(input, # always UTF-8
                                                  shiny_prerendered_dependencies,
                                                  files_dir,
                                                  output_dir) {



  # transform dependencies (if we aren't in debug mode)
  dependencies <- lapply(shiny_prerendered_dependencies, function(dependency) {

    # no transformation in dev mode (so browser dev tools can map directly
    # to the locations of CSS and JS files in their pkg src directory)
    if (nzchar(Sys.getenv("RMARKDOWN_SHINY_PRERENDERED_DEVMODE")))
      return(dependency)

    # see if we can convert absolute paths into package-aliased ones
    if (is.null(dependency$package) && !is.null(dependency$src$file)) {

      # check for a package directory parent
      package_dir <- tryCatch(
        find_root(is_r_package, path = dependency$src$file),
        error = function(e) NULL
      )
      # if we have one then populate the package field and make the
      # src$file relative to the package
      if (!is.null(package_dir)) {
        package_desc <- read.dcf(file.path(package_dir, "DESCRIPTION"),
                                 all = TRUE)
        dependency$package <- package_desc$Package
        dependency$src$file <- normalized_relative_to(package_dir,
                                                      dependency$src$file)
      }
    }

    # if we couldn't resolve the src to a package then copy the files
    if (is.null(dependency$package) && !is.null(dependency$src$file)) {
      dependency <- htmltools::copyDependencyToDir(dependency, files_dir)
      dependency <- htmltools::makeDependencyRelative(dependency, output_dir)
      dependency$src = list(href = unname(dependency$src))
    }

    # return dependency
    dependency
  })

  # remove NULLs (excluded dependencies)
  dependencies <- dependencies[!sapply(dependencies, is.null)]

  # append them to the file (guarnateed to be UTF-8)
  con <- file(input, open="at", encoding = "UTF-8")
  on.exit(close(con), add = TRUE)

  # write deps to connection
  dependencies_json <- jsonlite::serializeJSON(dependencies, pretty = FALSE)
  shiny_prerendered_append_context(con, "dependencies", dependencies_json)
}


#' Clean prerendered content for the specified Rmd input file
#'
#' Remove the associated html file and supporting _files directory
#' for a shiny_prerendered documet.
#'
#' @param input Rmd input file to clean content for
#'
#' @export
shiny_prerendered_clean <- function(input) {

  # html file
  html_file <- file_with_ext(input, "html")
  if (file.exists(html_file))
    file.remove(html_file)

  # cache dir
  cache_dir <- knitr_root_cache_dir(input)
  if (dir_exists(cache_dir))
    unlink(cache_dir, recursive = TRUE)

  # files dir
  files_dir <- knitr_files_dir(input)
  if (dir_exists(files_dir))
    unlink(files_dir, recursive = TRUE)

  # data dir
  data_dir <- shiny_prerendered_data_dir(input)
  if (dir_exists(data_dir))
    unlink(data_dir, recursive = TRUE)
}


#' Add code to a shiny_prerendered context
#'
#' Programmatic equivalent to including a code chunk with a
#' context in a runtime: shiny_prerendered document.
#'
#' @param context Context name (e.g. "server", "server-start")
#' @param code Character vector with code
#' @param singleton Collapse multiple identical versions of this
#'   chunk into a single chunk.
#'
#' @export
shiny_prerendered_chunk <- function(context, code, singleton = FALSE) {

  # verify we are in runtime: shiny_prerendered
  if (!identical(knitr::opts_knit$get("rmarkdown.runtime"),"shiny_prerendered"))
      stop("The shiny_prerendered_chunk function can only be called from ",
           "within runtime: shiny_prerenered")

  # add the prerendered chunk to knit_meta
  knitr::knit_meta_add(list(
    structure(class = "shiny_prerendered", list(
      name = context,
      code = code,
      singleton = singleton
    ))
  ))

  # return NULL invisibly
  invisible(NULL)
}


#' Get the server startup code for a shiny_prerendered server instance
#'
#' @param server_envir Shiny server environment to get code for
#'
#' @keywords internal
#' @export
shiny_prerendered_server_start_code <- function(server_envir) {
  if (exists(".shiny_prerendered_server_start_code", envir = server_envir))
    get(".shiny_prerendered_server_start_code", envir = server_envir)
  else
    ""
}


# Record which context="data" chunks are actually executed during
# the current render as well as the file names they are saved with.
# We'll use this later to determine which .RData files in the _data
# directory should actually be loaded (as some could be from chunks
# that used to be cached / were cached under different names)
shiny_prerendered_option_hook <- function(input, encoding) {
  function(options) {

    # convert chunk labels to contexts as necessary
    if (options$label %in% c("setup", "data", "server_start", "server"))
      options$context <- options$label

    if (identical(options$context, "data")) {
      data_file <- shiny_prerendered_data_file_name(options$label,
                                                    options$cache > 0)
      data_file <- to_utf8(data_file, encoding)
      data_dir <- shiny_prerendered_data_dir(input, create = TRUE)
      index_file <- shiny_prerendred_data_chunks_index(data_dir)
      conn <- file(index_file, open = "ab", encoding = "UTF-8")
      on.exit(close(conn), add = TRUE)
      write(data_file, file = conn, append = TRUE)
    }
    options
  }
}

# Evaluate hook to capture chunks with e.g. context="server" and
# append their code to the appropriate shiny_prerendered_context
shiny_prerendered_evaluate_hook <- function(input) {

  function(code, envir, ...) {

    # get the context (default to "render")
    context <- knitr::opts_current$get("context")
    if (is.null(context))
      context <- "render"

    # "setup" is an alias for c("render", "server-start")
    if ("setup" %in% context) {
      context <- c(context[!context == "setup"], "render", "server-start")
      context <- unique(context)
    }

    # if there are server-side contexts then emit knit_meta for them
    for (name in context) {
      if (!name %in% c("render"))
        shiny_prerendered_chunk(name, code)
    }

    # capture and serialize data for context = "data"
    if ("data" %in% context) {

      # determine whether caching is active
      label <- knitr::opts_current$get("label")
      cache_option <- knitr::opts_current$get("cache")
      cache <- !is.null(cache_option) && cache_option > 0

      # evaluate the chunk in a new environment parented by the default envir
      data_env <- new.env(parent = envir)
      result <- evaluate::evaluate(code, data_env, ...)

      # save all of the created objects then move them back into the parent
      data_dir <- shiny_prerendered_data_dir(input, create = TRUE)
      # use a special path prefix for cached chunks so we know not
      # to remove them at the beginning of render
      rdata_file <- file.path(data_dir,
                              shiny_prerendered_data_file_name(label, cache))
      save(list = ls(data_env),
           file = rdata_file,
           envir = data_env,
           compress = FALSE)

      for (name in ls(data_env)) {
        assign(name, get(name, envir = data_env), envir = envir)
        remove(list = c(name), envir = data_env)
      }

      # return results of evaluation (used for knitr cache)
      result
    }

    # straight evaluate if this is a render context
    else if ("render" %in% context) {
      evaluate::evaluate(code, envir, ...)
    }

    # otherwise parse so we can throw an error for invalid code
    else {
      parse(text = code)
      list()
    }
  }
}

# Remove prerendered .RData that isn't in the cache (as data in the
# cache won't necessarily be recreated during the next render)
shiny_prerendered_remove_uncached_data <- function(input) {
  data_dir <- shiny_prerendered_data_dir(input)
  if (dir_exists(data_dir)) {
    index_file <- shiny_prerendred_data_chunks_index(data_dir)
    if (file.exists(index_file))
      unlink(index_file)
    rdata_files <- list.files(data_dir, pattern = utils::glob2rx("*.RData"))
    cached_rdata_files <- list.files(data_dir, pattern = utils::glob2rx("*.cached.RData"))
    uncached_rdata_files <- setdiff(rdata_files, cached_rdata_files)
    unlink(file.path(data_dir, uncached_rdata_files))
  }
}



# Extract application/shiny-prerendered script tags from an html document
shiny_prerendered_extract_context <- function(html_lines, context) {

  # look for lines that start the context
  pattern <- paste0('<script type="application/shiny-prerendered" data-context="', context, '">')
  matches <- regmatches(html_lines, regexec(pattern, html_lines, fixed = TRUE))

  # extract the code within the contexts
  in_context <- FALSE
  context_lines <- character()
  for (i in 1:length(matches)) {
    if (length(matches[[i]]) > 0) {
      in_context <- TRUE
      next
    }
    else if (in_context && identical(html_lines[[i]], "</script>")) {
      in_context <- FALSE
    }
    if (in_context)
      context_lines <- c(context_lines, html_lines[[i]])
  }

  # unescape code, see https://github.com/rstudio/rmarkdown/issues/943
  context_lines <- gsub("<\\u002f", "</", context_lines, fixed = TRUE)
  context_lines
}

shiny_prerendered_remove_contexts <- function(html_lines, contexts) {

  # look for lines that start the contexts
  pattern <- paste0('<script type="application/shiny-prerendered" data-context="')
  matches <- regmatches(html_lines, regexec(pattern, html_lines, fixed = TRUE))

  # create a regex pattern used for matching named contexts
  contexts_pattern <- paste0(pattern, "(", paste(contexts, collapse = "|"), ")")

  # new_html_lines to return
  new_html_lines <- character()

  # ignore the code within the contexts
  in_context <- FALSE
  for (i in 1:length(matches)) {
    if (length(matches[[i]]) > 0 && grepl(contexts_pattern, html_lines[[i]])) {
      in_context = TRUE
    }
    else if (in_context && identical(html_lines[[i]], "</script>")) {
      in_context <- FALSE
    }
    else if (!in_context)
      new_html_lines <- c(new_html_lines, html_lines[[i]])
  }

  # return
  new_html_lines
}



# Gather shiny_prerendred contexts and append them as script tags to
# the passed file
shiny_prerendered_append_contexts <- function(runtime, file, encoding) {

  # collect contexts
  shiny_prerendered_contexts <- knit_meta_reset(class = "shiny_prerendered")
  if (length(shiny_prerendered_contexts) > 0) {

    # validate we are in runtime: shiny_prerendered
    if (!is_shiny_prerendered(runtime)) {
      stop("The code within this document requires runtime: shiny_prerendered",
           call. = FALSE)
    }

    # open the file
    con <- file(file, open="at", encoding = encoding)
    on.exit(close(con), add = TRUE)

    # track singletons
    singletons <- list()

    # append the contexts as script tags
    for (context in shiny_prerendered_contexts) {

      # resovle singletons
      if (isTRUE(context$singleton)) {
        found_singleton <- FALSE
        for (singleton in singletons) {
          if (identical(context, singleton)) {
            found_singleton <- TRUE
            break
          }
        }
        if (found_singleton)
          next
        else
          singletons[[length(singletons)+1]] <- context
      }

      # append context
      shiny_prerendered_append_context(con, context$name, context$code)
    }
  }
}

shiny_prerendered_append_context <- function(con, name, code) {
  lines <- c('<!--html_preserve-->',
             paste0('<script type="application/shiny-prerendered" ',
                    'data-context="', name ,'">'),
             # escape code, see https://github.com/rstudio/rmarkdown/issues/943
             gsub("</", "<\\u002f", code, fixed = TRUE),
             '</script>',
             '<!--/html_preserve-->')
  writeLines(lines, con = con)
}


# Prerendred data_dir for a given Rmd input file
shiny_prerendered_data_dir <- function(input, create = FALSE) {
  data_dir <- paste0(tools::file_path_sans_ext(input), "_data")
  if (create && !dir_exists(data_dir))
    dir.create(data_dir)
  data_dir
}


# Load prerendred data into the server environment. There are two
# reasons we load data based on a previously generated index file:
#
# (1) We don't remove all of the previously generated .RData files
#     at the beginning of a render. Specifically, we don't remove
#     .RData files that were created within a chunk w/ caching
#     enabled, since that .RData won't necessarily be re-created on
#     the next render. This means that we could be left with "stale"
#     .RData files from cached chunks. Reading based on the list
#     ensures that we only read .RData for chunks that were
#     included in the last rendered document.
#
# (2) We want to load data into the server environemnt in the
#     exact same chunk order that it appears in the document.
#
shiny_prerendered_data_load <- function(input_rmd, server_envir) {
  # check for data_dir
  data_dir <- shiny_prerendered_data_dir(input_rmd)
  if (dir_exists(data_dir)) {
    # read index of data files
    index_file <- shiny_prerendred_data_chunks_index(data_dir)
    if (file.exists(index_file)) {
      rdata_files <- readLines(index_file, encoding = "UTF-8")
      # load each of the files in the index
      for (rdata_file in rdata_files) {
        rdata_file <- file.path(data_dir,rdata_file)
        if (file.exists(rdata_file)) # won't exist if the chunk has no code
          load(rdata_file, envir = server_envir)
      }
    }
  }
}

# File used to store names of chunks which had cache=TRUE during the last render
shiny_prerendred_data_chunks_index <- function(data_dir) {
  file.path(data_dir, "data_chunks_index.txt")
}

# Form the name of a shiny_prerendered .RData file
shiny_prerendered_data_file_name <- function(label, cache) {
  type <- ifelse(cache, ".cached", "")
  sprintf("%s%s.RData", label, type)
}

