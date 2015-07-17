(ns pixie.reader
  (:require [pixie.string :as string]))

(def *current-ns* nil)
(set-dynamic! (var *current-ns*))


(defprotocol IPushbackReader
  (read-ch [this])
  (unread-ch [this]))

(defprotocol IMetadataReader
  (metadata [this]))

(deftype IndexedReader [s idx]
  IPushbackReader
  (read-ch [this]
    (if (>= idx (count s))
      :eof
      (let [ch (nth s idx)]
        (set-field! this :idx (inc idx))
        ch)))
  (unread-ch [this]
    (set-field! this :idx (dec idx))))

(defn indexed-reader [s]
  (->IndexedReader s 0))

(deftype UserSpaceReader [string-rdr reader-fn]
  IPushbackReader
  (read-ch [this]
    (when-not string-rdr
      (let [result (reader-fn)]
        (if (eof? result)
          (set-field! this :string-rdr :eof)
          (set-field! this :string-rdr (->IndexedReader result 0)))))

    (if (eof? string-rdr)
      :eof
      (let [v (read-ch string-rdr)]
        (if (eof? v)
          (do (set-field! this :string-rdr nil)
              (read-ch this))
          v))))
  (unread-ch [this]
    (unread-ch string-rdr)))

(defn user-space-reader [f]
  (->UserSpaceReader nil f))


(deftype MetaDataReader [parent-reader line-number column-number line
                         prev-line-number prev-column-number prev-line prev-chr
                         filename has-unread cur-chr]
  IPushbackReader
  (read-ch [this]
    (if has-unread
      (do (set-field! this :has-unread false)
          prev-chr)
      (let [ch (read-ch parent-reader)]
        (set-field! this :prev-column-number column-number)
        (set-field! this :prev-line-number line-number)
        (set-field! this :prev-line prev-line)
        (when (string? @line)
          (set-field! this :line (atom [])))
        (if (identical? ch \n)
          (do (swap! line (fn [x] (apply str x)))
              (set-field! this :line-number (inc line-number))
              (set-field! this :column-number 0))
          (do (swap! line conj ch)
              (set-field! this :column-number (inc column-number))))
        
        (set-field! this :cur-chr ch)
        ch)))

  (unread-ch [this]
    (assert (not has-unread) "Can't unread twice")
    (set-field! this :has-unread true)
    (set-field! this :prev-chr cur-chr))

  IMetadataReader
  (metadata [this]
    {:line line
     :line-number line-number
     :column-number column-number
     :file filename}))

(defn metadata-reader [parent file]
  (->MetaDataReader parent 1 0 (atom []) 1 0 nil \0 file false \0))


(def whitespace? (contains-table \return \newline \, \space \tab))

(def digit? (apply contains-table "0123456789"))

(defn eof? [x]
  (identical? x :eof))

(defn terminating-macro? [ch]
  (and (not= ch \#)
       (not= ch \')
       (not= ch \%)
       (handlers ch)))

(defn eat-whitespace [rdr]
  (let [ch (read-ch rdr)]
    (if (whitespace? ch)
        (eat-whitespace rdr)
        ch)))

(defn assert-not-eof [ch msg]
  (assert (not (identical? ch :eof)) msg))

(defn make-coll-reader [build-fn open-ch close-ch]
  (fn rdr-internal
    ([rdr]
     (rdr-internal rdr []))
    ([rdr coll]
     (let [ch (eat-whitespace rdr)]
       #_(assert-not-eof ch (str "Unmatched delimiter " open-ch))
       (if (identical? ch close-ch)
         (apply build-fn coll)
         (let [_ (unread-ch rdr)
               itm (read-inner rdr true false)]
           (if (identical? itm rdr)
             (rdr-internal rdr coll)
             (rdr-internal rdr (conj coll itm)))))))))


(defn make-unmatched-handler [unhandled-ch]
  (fn [rdr]
    (throw [:pixie.reader/ParseError
            (str "Unmatched delimiter " unhandled-ch)])))


(def *gen-sym-env* nil)
(set-dynamic! (var *gen-sym-env*))

(defn syntax-quote-reader [rdr]
  (let [form (read-inner rdr true)]
    (binding [*gen-sym-env* {}]
      (syntax-quote form))))

(defn unquote? [form]
  (and (seq? form)
       (= (first form) 'unquote)))

(defn unquote-splicing? [form]
  (and (seq? form)
       (= (first form) 'unquote-splicing)))

(defn syntax-quote [form]
  (cond
    (and (symbol? form)
         nil ; TODO: Compiler special
         )
    (list 'quote form)

    (symbol? form)
    (cond
      (namespace form)
      (list 'quote form)

      (string/ends-with? (name form) "#")
      (let [gmap *gen-sym-env*
            _ (assert gmap "Gensym literal used outside of a syntax quote")
            gs (or (get gmap form)
                   (let [s (gensym (str (name form) "__"))]
                     (set! *gen-sym-env* (assoc gmap form s))
                     s))]
        (list 'quote gs))

      :else
      (list 'quote (symbol (str (name *current-ns*) "/" (name form)))))

    (unquote? form)
    (first (next form))

    (unquote-splicing? form)
    (assert false "Unquote splicing used outside a list")

    (vector? form)
    (list 'pixie.stdlib/apply 'pixie.apply/concat (expand-list form))

    (and form (seq? form))
    (list 'pixie.stdlib/apply 'pixie.stdlib/list (expand-list form))

    :else (list 'quote form)))

(defn expand-list [form]
  (reduce
   (fn [acc itm]
     (cond
       (unquote? itm)
       (conj acc [(nth form 1)])

       (unquote-splicing? form)
       (conj acc (nth form 1))

       :else (conj acc (syntax-quote itm))))
   []
   form))

(defn deref-reader [rdr]
  (list 'pixie.stdlib/deref (read-inner rdr true)))


(defn skip-line-reader [rdr]
  (if (identical? \n (read-ch rdr))
    rdr
    (skip-line rdr)))

(defn meta-reader [rdr]
  (let [m (read-inner rdr true)
        o (read-inner rdr true)
        m (cond
            (keyword? m) {m true}
            (symbol? m) {:tag m}
            :else m)]
    (if (has-meta? o)
      (with-meta o m)
      o)))

(defn unquote-reader [rdr]
  (let [ch (read-ch rdr)
        sym (if (identical? ch \@)
              'pixie.stdlib/unquote-splicing
              (do (unread-ch rdr)
                  'pixie.stdlib/unquote))
        form (read-inner rdr true)]
    (list sym form)))

(def string-literals
  (switch-table
   \" \"
   \\ \\
   \n \newline
   \r \return
   \t \tab))

(defn literal-string-reader [rdr]
  (let [sb (string-builder)
        sb-fn (fn [x]
                (-add-to-string-builder sb x))]
    (loop []
      (let [ch (read-ch rdr)]
        (cond
          (eof? ch) (throw [:pixie.reader/ParseError
                           "Unmatched string quote"])
          (identical? \" ch) (str sb)

          (identical? \\ ch) (let [v (read-ch rdr)
                                   _ (when (eof? v)
                                       (throw [:pixie.reader/ParseError
                                               "End of file after escape character"]))
                                   converted (string-literals v)]
                               (if converted
                                 (do (sb-fn converted)
                                     (recur))
                                 (throw [:pixie.reader/ParseError
                                         (str "Unhandled escape character " v)])))
          :else (do (sb-fn ch)
                    (recur)))))))

(defn keyword-reader [rdr]
  (let [ch (read-ch rdr)]
    (assert (not= \: ch))
    (let [itm (read-symbol rdr ch)]
      (if (namespace itm)
        (keyword (str (namespace itm) "/" (name itm)))
        (keyword (name itm))))))

(def handlers
  (switch-table
   \( (make-coll-reader list \( \))
   \[ (make-coll-reader vector \[ \])
   \{ (make-coll-reader hashmap \{ \})
   \] (make-unmatched-handler \])
   \) (make-unmatched-handler \))
   \} (make-unmatched-handler \})
   \: keyword-reader
   \` syntax-quote-reader
   \@ deref-reader
   \; skip-line-reader
   \^ meta-reader
   \~ unquote-reader
   \" literal-string-reader))

(defn read-number [rdr ch]
  (let [sb (string-builder)
        sb-fn (fn [x]
                (-add-to-string-builder sb x))]
    (-str ch sb-fn)
    (loop [sb-fn sb-fn]
      (let [ch (read-ch rdr)]
        (if (or (whitespace? ch)
                (terminating-macro? ch)
                (eof? ch))
         
          (let [val (-parse-number (str sb))]
            (unread-ch rdr)
            (if val
              val
              (symbol val)))
          (do (-str ch sb-fn)
              (recur sb-fn)))))))


(defn read-symbol [rdr ch]
  (let [sb (string-builder)
        sb-fn (fn [x]
                (-add-to-string-builder sb x))]
    (-str ch sb-fn)
    (loop [sb-fn sb-fn]
      (let [ch (read-ch rdr)]
        (if (or (whitespace? ch)
                (terminating-macro? ch)
                (eof? ch))
         
          (let [val (interpret-symbol (str sb))]
            (unread-ch rdr)
            val)
          (do (-str ch sb-fn)
              (recur sb-fn)))))))

(defn interpret-symbol [s]
  (cond
    (= s "true") true
    (= s "false") false
    (= s "nil") nil
    :else (symbol s)))


(defn read-inner
  ([rdr eof-on-error]
   (read-inner rdr eof-on-error true))
  ([rdr eof-on-error always-return-form]
   (let [ch (eat-whitespace rdr)]
     (if (identical? ch :eof)
       (if eof-on-error
         (assert-not-eof ch "Unexpeced EOF while reading")
         ch)
       (let [m (when (satisfies? IMetadataReader rdr)
                 (metadata rdr))
             macro (handlers ch)
             itm (cond
                   macro (let [itm (macro rdr)]
                           (if (and always-return-form
                                    (identical? itm rdr))
                             (read-inner rdr error-on-eof always-return-form)
                             itm))
                   (digit? ch) (read-number rdr ch)
                   (identical? ch \-) (let [ch2 (read-ch rdr)]
                                        (if (digit? ch2)
                                          (do (unread-ch rdr)
                                              (read-number rdr ch))
                                          (do (unread-ch rdr)
                                              (read-symbol rdr ch))))
                   :else (read-symbol rdr ch))]
         (if (identical? itm rdr)
           itm
           (if (has-meta? itm)
             (with-meta itm m)
             itm)))))))

(defn read [rdr error-on-eof]
  (read-inner rdr error-on-eof))


(defn read-string [s]
  (read (->IndexedReader s 0)
        false))